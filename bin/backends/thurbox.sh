#!/usr/bin/env bash
# bin/backends/thurbox.sh - the thurbox session-provider adapter (EXPERIMENTAL).
#
# thurbox (https://github.com/Thurbeen/thurbox) is a session manager for coding
# agents: a ratatui TUI plus a `thurbox-cli` over a SQLite session database,
# whose sessions are REAL TMUX WINDOWS on a tmux server of its own
# (`backend_type: "local-tmux"`, its socket named by `thurbox-cli version`'s
# `tmux_socket`, "thurbox" on the verified build). thurbox is a session
# provider ONLY here: the worktree provider stays treehouse, exactly like tmux,
# herdr, zellij, and cmux. thurbox CAN own worktrees natively (`session create
# --worktree-branch/--base-branch`), but adopting that would make it a
# worktree provider like Orca and is deliberately out of scope for this
# adapter - see docs/thurbox-backend.md "Why not the worktree provider".
# Sourced only through bin/fm-backend.sh's fm_backend_source in normal
# operation; the unit tests source it directly.
#
# THE DEFINING PROPERTY, and why this adapter is a two-CLI adapter: every
# thurbox session is addressable BOTH ways.
#   - `thurbox-cli session ...` owns SESSION-level identity and lifecycle
#     (create, get, delete, the native hook_state). Its key is a UUID.
#   - `tmux -L <thurbox-socket> ...` owns PANE-level primitives against the
#     very same window (literal unsubmitted input, named special keys, an
#     ANSI-preserving screen capture, the cursor row, the live cwd).
# The thurbox CLI alone cannot satisfy firstmate's contract: `session send`
# ALWAYS appends Enter (verified; its own --help says "followed by Enter"), so
# it can never implement send_literal's unsubmitted-input requirement, and the
# CLI exposes no named-key, styled-capture, or cursor primitive at all. Going
# through thurbox's own tmux socket for those is not a layering violation - it
# is addressing the same window thurbox itself created, with the primitives
# thurbox is itself built on. It is also what makes thurbox the FIRST non-tmux
# backend to reach tmux's own composer fidelity (styled=1 AND cursor=1), where
# zellij manages styled=1/cursor=0 and cmux and orca only styled=0/cursor=0.
#
# Target string shape: "<session-uuid>:<tmux-pane-id>" (e.g.
# "0b797791-3590-41c5-9918-21e38d1a54d4:%20"). A UUID contains no colon, so
# splitting on the FIRST colon is trivially correct, mirroring herdr's,
# zellij's, and cmux's target convention. Both atoms pass
# fm_backend_endpoint_atom_valid (hex-and-dash; tmux pane ids are "%<n>").
#
# IDENTITY MODEL - the single most load-bearing finding, and the one that
# shapes every function below: THE UUID IS DURABLE, THE PANE ID IS A CACHE.
# Verified live: `thurbox-cli session restart <uuid>` kills the window and
# re-spawns it, and the session's `backend_id` moved %23 -> %24 while the UUID
# stayed identical. So every operation here re-resolves the pane id from the
# UUID through `session get` (fm_backend_thurbox_target_ready) instead of
# trusting the pane id recorded in task meta. This is strictly better than
# cmux's situation (where ids do not survive an app relaunch and the only
# durable handle is a TITLE, which cmux does not enforce unique): thurbox's
# UUID is a real SQLite primary key, so recovery is exact rather than
# best-effort. The recorded pane id is kept in meta only as a debugging
# breadcrumb and a fast path; it is never the authority.
#
# Empirical verification (real thurbox 2.9.2, schema 40, Linux x86_64,
# 2026-08-28; docs/thurbox-backend.md holds the full evidence log). Findings
# that are load-bearing for this adapter:
#
#   1. `session create --json` does NOT return `backend_id` - only
#      id/name/cwd/agent/agent_session_id. The pane id needs a SECOND
#      `session get` call, which is why create polls for it below rather than
#      reading it from the create response.
#   2. thurbox enforces NO name uniqueness: creating a second session named
#      "fm-verify-1" succeeded and returned a different UUID, leaving two live
#      windows with the same tmux window name. The duplicate refusal below is
#      OURS, mirroring herdr's, zellij's, and cmux's identical posture.
#   3. The tmux window name is NOT the session name: thurbox prefixes it
#      ("fm-verify-1" -> window "tb-fm-verify-1"). Nothing here may match on
#      window names; the session NAME in the database is the label authority.
#   4. Exit codes are HONEST, unlike zellij's always-0 `action` surface:
#      `session get`, `session capture`, and `session send` all return 1 for a
#      missing OR malformed UUID. That makes `session get` a sound liveness
#      primitive on its own, with no output-shape defence needed.
#   5. `session delete --force` really does reclaim the window
#      (`"killed_window": true`), and also removes worktrees and cancels
#      pending scheduled commands. The non-forced delete only soft-deletes the
#      DB row and defers window cleanup to the TUI's next sync - useless for a
#      headless teardown, so kill always passes --force.
#   6. `session signal --state <working|blocked|done|idle>` writes the
#      session's `hook_state`, and `session get --json` reads it back
#      (verified round-trip). thurbox's agents call this from their own
#      lifecycle hooks (see its agents.toml, e.g. aider's
#      --notifications-command). The vocabulary is WORD-FOR-WORD herdr's
#      agent_status vocabulary, so fm_backend_thurbox_busy_state below reuses
#      herdr's exact mapping. `hook_state` is null until an agent first
#      signals, which classifies as unknown.
#   7. A thurbox instance spawns an `automation-heartbeat` tmux window on its
#      socket the first time a session is created in it. It is thurbox's own
#      housekeeping, not a task window; list_live's name-prefix scoping
#      ignores it, and this is also why the unit tests stub the CLI and never
#      call a real `session create` (tests/thurbox-test-safety.sh).
#   8. THURBOX_CONFIG_DIR and THURBOX_DATA_DIR relocate a thurbox instance's
#      config and database, which is how the live verification ran fully
#      isolated from the operator's own sessions. They do NOT relocate the
#      tmux socket, which stays shared - the reason finding 7 matters.
#
# Requires: thurbox-cli, tmux, jq. Bootstrap detects these through
# fm_backend_required_tools only when thurbox is the resolved backend; this
# adapter also gates them again before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/{herdr,zellij,cmux}.sh's identical fallback.
FM_BACKEND_THURBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_THURBOX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_THURBOX_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_THURBOX_ROOT/bin/fm-composer-lib.sh"
# Cursor's process identity has exactly one owner fleet-wide; this adapter
# needs it for the same cursor-parked-outside-the-composer hazard the default
# tmux backend mitigates.
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_BACKEND_THURBOX_ROOT/bin/fm-cursor-lib.sh"

# Verified minimum: the version the live pass ran against
# (docs/thurbox-backend.md). 2.9 is where `session capture --json`, the
# `hook_state` round-trip, and `delete --force`'s killed_window report were all
# confirmed together.
FM_BACKEND_THURBOX_MIN_MAJOR=2
FM_BACKEND_THURBOX_MIN_MINOR=9

# thurbox session names are 1-64 chars with no slashes and no leading '.'
# (verified from `session create --name`'s own help text). The scoped title
# below is checked against this so an over-long secondmate home tag fails
# LOUDLY at spawn instead of being silently truncated by thurbox.
FM_BACKEND_THURBOX_NAME_MAX=64

# fm_backend_thurbox_bin: the thurbox CLI. FM_THURBOX_BIN is the test seam
# (tests point it at a stub; nothing in normal operation sets it), mirroring
# how the cmux adapter resolves its own binary through one function.
fm_backend_thurbox_bin() {
  if [ -n "${FM_THURBOX_BIN:-}" ]; then
    printf '%s' "$FM_THURBOX_BIN"
    return 0
  fi
  command -v thurbox-cli >/dev/null 2>&1 || return 1
  printf 'thurbox-cli'
}

fm_backend_thurbox_tool_check() {
  fm_backend_thurbox_bin >/dev/null 2>&1 || { echo "error: backend=thurbox selected but the 'thurbox-cli' CLI was not found on PATH (https://github.com/Thurbeen/thurbox)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=thurbox selected but 'jq' is not installed (required to parse thurbox's JSON output)" >&2; return 1; }
  command -v tmux >/dev/null 2>&1 || { echo "error: backend=thurbox selected but 'tmux' is not installed (thurbox sessions ARE tmux windows on thurbox's own socket; the pane primitives need the tmux client)" >&2; return 1; }
  return 0
}

# fm_backend_thurbox_cli: run `thurbox-cli <args...>`. Every call site asks for
# --json explicitly rather than having it forced here, because a few
# subcommands (notably `session capture`) carry their payload in a JSON field
# and others are pure side effects.
fm_backend_thurbox_cli() {  # <thurbox-cli-subcommand-and-args...>
  local bin
  bin=$(fm_backend_thurbox_bin) || return 1
  "$bin" "$@"
}

# fm_backend_thurbox_version_check: refuse loudly on a missing/incompatible
# thurbox. `version --json` needs no running TUI (verified headless), so this
# is a pure client gate.
#
# `version` is spelled out rather than passing --version: thurbox's own help
# records that clap's implicit --version reads a static "0.0.0-dev" marker the
# project never bumps, and only the `version` SUBCOMMAND reports the real
# build. Reading --version here would reject every correct install.
fm_backend_thurbox_version_check() {
  fm_backend_thurbox_tool_check || return 1
  local raw ver major rest minor
  raw=$(fm_backend_thurbox_cli version --json 2>/dev/null) || { echo "error: 'thurbox-cli version' failed; is thurbox installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | jq -r '.version // empty' 2>/dev/null)
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a thurbox version from '$raw'; refusing to use an unverified thurbox build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_THURBOX_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_THURBOX_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_THURBOX_MIN_MINOR" ]; }; then
    echo "error: thurbox $ver is older than the verified minimum $FM_BACKEND_THURBOX_MIN_MAJOR.$FM_BACKEND_THURBOX_MIN_MINOR; update thurbox before using backend=thurbox" >&2
    return 1
  fi
  return 0
}

# fm_backend_thurbox_socket: the tmux socket name thurbox runs its sessions on,
# read from `version --json`'s `tmux_socket` field ("thurbox" on the verified
# build) and memoized per shell. Never hardcoded: it is thurbox's own reported
# value, so a build that changes it does not silently strand every pane
# primitive against a socket with no server.
fm_backend_thurbox_socket() {
  if [ -n "${FM_BACKEND_THURBOX_SOCKET_CACHE:-}" ]; then
    printf '%s' "$FM_BACKEND_THURBOX_SOCKET_CACHE"
    return 0
  fi
  local sock
  sock=$(fm_backend_thurbox_cli version --json 2>/dev/null | jq -r '.tmux_socket // empty' 2>/dev/null)
  [ -n "$sock" ] || return 1
  FM_BACKEND_THURBOX_SOCKET_CACHE=$sock
  printf '%s' "$sock"
}

# fm_backend_thurbox_tmux: run a tmux command against THURBOX's socket, never
# the ambient default one. Every pane-level primitive in this file goes through
# here, so no call site can accidentally address the operator's own tmux server
# (or firstmate's own "firstmate" session) instead of thurbox's.
fm_backend_thurbox_tmux() {  # <tmux-args...>
  fm_backend_thurbox_socket >/dev/null || return 1
  tmux -L "$FM_BACKEND_THURBOX_SOCKET_CACHE" "$@"
}

# fm_backend_thurbox_agent: the thurbox agent entry firstmate launches its
# sessions with, from config/thurbox-agent (first non-empty line), defaulting
# to "shell".
#
# WHY AN AGENT ENTRY AT ALL: firstmate's spawn pipeline needs a BARE
# INTERACTIVE SHELL in the new pane - it runs `treehouse get` itself, then
# launches the selected harness with its own model/effort/yolo flags
# (bin/fm-spawn.sh). thurbox's own job is normally the opposite: launch a
# coding agent for you. So a firstmate home configures thurbox with one extra
# agents.toml entry whose command is an interactive shell, and this adapter
# names it. docs/thurbox-backend.md "Setup" owns that one-time config, and
# fm_backend_thurbox_container_ensure below verifies it before the first spawn
# instead of letting a missing entry surface as a mystifying agent launch.
fm_backend_thurbox_agent() {
  local config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" f line
  f="$config_dir/thurbox-agent"
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$line" ]; then
        printf '%s' "$line"
        return 0
      fi
    done < "$f"
  fi
  printf 'shell'
}

# fm_backend_thurbox_agent_defined: is the configured agent actually present in
# thurbox's agents.toml? `config validate --json` reports agents.toml validity
# but not its entry names, so this asks the authoritative question the cheap
# way - a spawn with an unknown --agent is what would otherwise fail late.
fm_backend_thurbox_agent_defined() {  # <agent-name>
  local agent=$1 out
  out=$(fm_backend_thurbox_cli config validate --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e '.agents_toml.valid == true' >/dev/null 2>&1 || return 1
  # agents.toml's own path is reported by config validate; read the entry names
  # from it directly, since no CLI subcommand lists them.
  local path
  path=$(printf '%s' "$out" | jq -r '.agents_toml.path // empty' 2>/dev/null)
  [ -n "$path" ] && [ -f "$path" ] || return 1
  # Scoped to an actual [[agents]] table, and compared LITERALLY rather than as
  # an interpolated regex. Both matter: agents.toml also carries hook, profile,
  # and sharing tables that have their own `name` keys, so an unscoped search
  # would report a missing agent as defined and push the failure back out to
  # `session create --agent`, which is exactly what this gate exists to
  # prevent; and an agent name carrying a regex metacharacter (`fm.shell`)
  # would otherwise match a different entry (`fmXshell`). TOML accepts both
  # quote styles for a basic string, so both are matched.
  #
  # A trailing comment is stripped first, on the header line as well as the
  # name line, because this gate exists to turn a late, mystifying agent-launch
  # failure into an early actionable one - and a scan that reads an ordinary
  # commented `name = "shell" # ...` as undefined would BE the mystifying
  # failure, refusing every spawn while telling the operator to add an entry
  # thurbox itself already accepts. The strip tracks quote state so a `#`
  # inside the value is a literal, not a comment. Header matching likewise
  # tolerates TOML's permitted inner whitespace (`[[ agents ]]`), since a
  # header this scan fails to recognize silently skips that whole table.
  awk -v want="$agent" '
    function uncomment(s,   i, c, q, n) {
      q = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\"" && c == "\\") { i++; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "#") return substr(s, 1, i - 1)
        if (c == "\"" || c == "\047") q = c
      }
      return s
    }
    {
      line = uncomment($0)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^\[/) {
        in_agents = (line ~ /^\[\[[[:space:]]*agents[[:space:]]*\]\]$/)
        next
      }
      if (!in_agents) next
      if (line !~ /^name[[:space:]]*=[[:space:]]*/) next
      sub(/^name[[:space:]]*=[[:space:]]*/, "", line)
      q = substr(line, 1, 1)
      if (q != "\"" && q != "\047") next
      if (length(line) < 2 || substr(line, length(line), 1) != q) next
      if (substr(line, 2, length(line) - 2) == want) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$path"
}

# fm_backend_thurbox_container_ensure: the full spawn-time container-ensure
# sequence. Unlike herdr and zellij there is NO per-home container to stand up:
# thurbox has no session-of-sessions layer, its database is the container, and
# `thurbox-cli` works fully headless (verified - no running TUI required). So
# this is a gate, not a constructor: version, reachable tmux socket, and the
# configured shell agent. Nothing to echo; callers proceed straight to
# fm_backend_thurbox_create_task.
fm_backend_thurbox_container_ensure() {
  fm_backend_thurbox_version_check || return 1
  local agent
  if ! fm_backend_thurbox_socket >/dev/null 2>&1; then
    echo "error: could not read thurbox's tmux socket name from 'thurbox-cli version --json' (.tmux_socket); refusing to guess it" >&2
    return 1
  fi
  agent=$(fm_backend_thurbox_agent)
  if ! fm_backend_thurbox_agent_defined "$agent"; then
    echo "error: backend=thurbox needs a thurbox agent named '$agent' that launches an INTERACTIVE SHELL (firstmate runs treehouse and launches the harness itself). Add it to thurbox's agents.toml, e.g. [[agents]] name = \"$agent\" / command = \"bash\" / args = [\"-i\"] - see docs/thurbox-backend.md 'Setup' - or name a different entry in config/thurbox-agent." >&2
    return 1
  fi
  return 0
}

# fm_backend_thurbox_home_label / _scoped_title: thurbox's session-name
# namespace is global to one thurbox database, shared by every firstmate home
# pointed at it, so task names carry this installation's home tag exactly as
# cmux's workspace titles and zellij's tab titles do. Derivation is the shared
# owner in bin/fm-backend-hometag-lib.sh.
#
# Unlike zellij and cmux there is NO legacy untagged form to migrate: this
# adapter has been home-scoped since its first commit, so every matcher below
# is exact-match on the scoped name with no ambiguity fallback to reason about.
fm_backend_thurbox_home_label() {
  fm_backend_hometag
}

fm_backend_thurbox_scoped_title() {  # <fm-task-label>
  local label=$1 rest home title
  home=$(fm_backend_thurbox_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  title=$(printf 'fm-%s-%s' "$home" "$rest")
  if [ "${#title}" -gt "$FM_BACKEND_THURBOX_NAME_MAX" ]; then
    echo "error: thurbox session name '$title' is ${#title} chars, over thurbox's $FM_BACKEND_THURBOX_NAME_MAX-char limit; shorten the task id or relocate this firstmate home to a shorter path" >&2
    return 1
  fi
  printf '%s' "$title"
}

# fm_backend_thurbox_session_row: the full `session get` JSON row for <uuid>,
# or nothing. thurbox's exit codes are honest here (finding 4), so a missing or
# malformed UUID simply fails - no output-shape defence needed.
fm_backend_thurbox_session_row() {  # <uuid>
  fm_backend_thurbox_cli session get "$1" --json 2>/dev/null
}

# fm_backend_thurbox_session_id_for_label: the live session UUID whose NAME
# equals <label>, or empty. thurbox enforces no name uniqueness (finding 2), so
# this adopts the FIRST match, mirroring herdr's/zellij's/cmux's posture; the
# duplicate refusal in create_task is what keeps a second one from appearing.
#
# "No such session" and "could not ask" are DIFFERENT answers and are reported
# differently: a listing that ran and matched nothing echoes nothing and
# succeeds, while a `session list` that failed - or answered something that is
# not a JSON array - returns non-zero and echoes nothing. Collapsing the two
# would let a locked database read as proof that a name is free, which is
# exactly the proof create_task's duplicate refusal rests on.
fm_backend_thurbox_session_id_for_label() {  # <label>
  local label=$1 list ids
  list=$(fm_backend_thurbox_cli session list --json 2>/dev/null) || return 1
  ids=$(printf '%s' "$list" | jq -r --arg want "$label" \
    'if type == "array" then (.[] | select(.name == $want) | .id) else error("not an array") end' \
    2>/dev/null) || return 1
  printf '%s' "$ids" | head -1
}

# fm_backend_thurbox_pane_exists: does <pane-id> currently exist on thurbox's
# tmux server? Structural existence check, never a content read - the analogue
# of zellij's fm_backend_zellij_pane_exists and cmux's surface check.
fm_backend_thurbox_pane_exists() {  # <pane-id>
  local pane=$1
  fm_backend_thurbox_tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1
}

# fm_backend_thurbox_create_task: create the task's thurbox session, refusing an
# existing live <label> (finding 2: thurbox enforces no uniqueness itself).
# `session create` runs SYNCHRONOUSLY - its own help promises the tmux window is
# live on return - but it does NOT report the pane id (finding 1), so the pane
# is resolved by a bounded `session get` poll afterwards. Echoes
# "<session_uuid> <pane_id>" on success.
#
# No focus-restore dance is needed (unlike zellij, whose new-tab steals focus
# with no flag to suppress it): thurbox's create only marks a focus REQUEST
# when explicitly asked via `session focus`, and a plain create leaves an
# attached TUI where it was.
fm_backend_thurbox_create_task() {  # <label> <cwd> -> "<uuid> <pane_id>"
  local label=$1 cwd=$2 title dup agent out uuid pane i
  title=$(fm_backend_thurbox_scoped_title "$label") || return 1
  dup=$(fm_backend_thurbox_session_id_for_label "$title") || {
    echo "error: could not list thurbox sessions, so '$title' cannot be proven free; refusing to create a possible duplicate" >&2
    return 1
  }
  if [ -n "$dup" ]; then
    echo "error: thurbox session '$title' already exists ($dup)" >&2
    return 1
  fi
  agent=$(fm_backend_thurbox_agent)
  out=$(fm_backend_thurbox_cli session create --name "$title" --repo-path "$cwd" --agent "$agent" --json 2>&1) || {
    echo "error: thurbox session create failed for '$title': $out" >&2
    return 1
  }
  uuid=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$uuid" ] || { echo "error: thurbox session create returned no session id for '$title': $out" >&2; return 1; }
  # Bounded poll for the pane id. The window is already live per create's
  # synchronous contract; this loop exists only because the pane id lives in a
  # different call's response, and it fails loudly rather than returning a
  # half-formed target.
  for i in $(seq 1 20); do
    pane=$(fm_backend_thurbox_session_row "$uuid" | jq -r '.backend_id // empty' 2>/dev/null)
    [ -n "$pane" ] && break
    sleep 0.25
  done
  if [ -z "$pane" ]; then
    echo "error: thurbox did not report a tmux pane id for session '$title' ($uuid) within 5s" >&2
    # Roll the half-formed session back. The row already holds the scoped
    # title, and the duplicate refusal above is exact-match on that title, so
    # a session left here would fail EVERY later spawn of this task id until
    # an operator deleted it by hand - a permanent wedge earned by one timeout.
    # --force because reclaiming the window is the point; a soft delete would
    # leave the row, and the row is what reserves the name.
    fm_backend_thurbox_cli session delete "$uuid" --force --json >/dev/null 2>&1 \
      || echo "warning: could not roll back thurbox session '$title' ($uuid); it still holds that name, so delete it with: thurbox-cli session delete $uuid --force" >&2
    return 1
  fi
  printf '%s %s' "$uuid" "$pane"
}

# fm_backend_thurbox_parse_target: split "<session_uuid>:<pane_id>" on the FIRST
# colon (a UUID contains no colon, so this is unambiguous). Sets
# FM_BACKEND_THURBOX_SESSION and FM_BACKEND_THURBOX_PANE for the caller.
fm_backend_thurbox_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_THURBOX_SESSION=${target%%:*}
  FM_BACKEND_THURBOX_PANE=${target#*:}
  [ -n "$FM_BACKEND_THURBOX_SESSION" ] && [ -n "$FM_BACKEND_THURBOX_PANE" ] && [ "$FM_BACKEND_THURBOX_PANE" != "$target" ]
}

# fm_backend_thurbox_target_ready: parse the target, then RE-RESOLVE the pane id
# from the durable session UUID before every operation. This is the identity
# model from this file's header made operational: `session restart` moves the
# pane (verified %23 -> %24) while the UUID is stable, so trusting the recorded
# pane id would silently address a dead pane - or, worse, a recycled one.
#
# Order of authority:
#   1. The recorded UUID's own row, when `session get` still returns one. The
#      row's `backend_id` REPLACES the target's pane id in
#      FM_BACKEND_THURBOX_PANE, so callers always act on the live pane.
#   2. When a caller supplies the owning task label, the row's `name` must
#      equal this home's scoped title for it. A row whose name is something
#      else is a DIFFERENT task (or another home's) and is refused outright.
#   3. When the UUID is gone entirely and a label was supplied, one lookup by
#      that scoped name recovers a session recreated behind firstmate's back.
#      Without a label there is nothing safe to fall back to, so it fails.
#
# A remote session (`session create --host`, `backend_type` other than
# "local-tmux") has NO pane on this machine's thurbox socket, so every pane
# primitive here would silently address nothing. Those are refused explicitly
# rather than half-working; docs/thurbox-backend.md "Current operation and
# safety" records that boundary under its Refusals paragraph.
# fm_backend_thurbox_resolve_row: steps 1 and 3 of that order of authority, and
# the single owner of "which session row IS this task's". Sets
# FM_BACKEND_THURBOX_ROW_UUID and FM_BACKEND_THURBOX_ROW on success and touches
# nothing on failure, so a caller's own target variables are only ever replaced
# by a row that was actually found. Kept separate from target_ready because
# teardown needs the row WITHOUT the pane liveness the rest of the adapter
# needs: the row, not the window, is what kill owns.
fm_backend_thurbox_resolve_row() {  # <uuid> [expected-title]
  local uuid=$1 expected_title=${2:-} row
  row=$(fm_backend_thurbox_session_row "$uuid")
  if [ -z "$row" ]; then
    [ -n "$expected_title" ] || return 1
    uuid=$(fm_backend_thurbox_session_id_for_label "$expected_title")
    [ -n "$uuid" ] || return 1
    row=$(fm_backend_thurbox_session_row "$uuid")
    [ -n "$row" ] || return 1
  fi
  FM_BACKEND_THURBOX_ROW_UUID=$uuid
  FM_BACKEND_THURBOX_ROW=$row
  return 0
}

fm_backend_thurbox_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} expected_title='' row name pane btype uuid
  fm_backend_thurbox_parse_target "$1" || return 1
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_thurbox_scoped_title "$expected_label" 2>/dev/null) || return 1
  fi
  fm_backend_thurbox_resolve_row "$FM_BACKEND_THURBOX_SESSION" "$expected_title" || return 1
  uuid=$FM_BACKEND_THURBOX_ROW_UUID
  row=$FM_BACKEND_THURBOX_ROW
  # One jq pass over the row rather than one per field: target_ready runs
  # before EVERY operation and twice per composer read, so this is the hot
  # path. Same one-pass tab-separated form fm_backend_thurbox_list_live uses.
  IFS=$'\t' read -r name pane btype <<EOF
$(printf '%s' "$row" | jq -r '"\(.name // "")\t\(.backend_id // "")\t\(.backend_type // "")"' 2>/dev/null)
EOF
  [ "$btype" = "local-tmux" ] || return 1
  if [ -n "$expected_label" ] && [ "$name" != "$expected_title" ]; then
    return 1
  fi
  [ -n "$pane" ] || return 1
  fm_backend_thurbox_pane_exists "$pane" || return 1
  FM_BACKEND_THURBOX_SESSION=$uuid
  FM_BACKEND_THURBOX_PANE=$pane
  return 0
}

# fm_backend_thurbox_current_path: the live pane's working directory, or empty
# on any error.
#
# This is the one place where being tmux-backed pays off most. herdr needs a
# `foreground_cwd` field, and zellij and cmux both had to fall back to an
# ACTIVE probe (print a marked $PWD into the pane, capture it back) because
# their passive cwd fields freeze at whatever directory the shell was in when
# it launched `treehouse get` as a foreground command. tmux's own
# `#{pane_current_path}` follows the pane's foreground process, which is
# exactly why the default tmux backend has always read it directly - and
# thurbox panes ARE tmux panes, so the same primitive is available with no
# probe, no marker, and no injected keystrokes during worktree discovery.
#
# thurbox's OWN `cwd` field is deliberately not used: it is the launch
# directory recorded in the database at create time and does not track the
# pane's later movement.
fm_backend_thurbox_current_path() {  # <target> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${2:-}" || return 0
  fm_backend_thurbox_tmux display-message -p -t "$FM_BACKEND_THURBOX_PANE" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_thurbox_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately.
#
# This CANNOT go through `thurbox-cli session send`: that subcommand always
# appends Enter ("Type text into a session's terminal, followed by Enter"),
# which would submit every steer the moment it was typed and make the shared
# submit-verify loop meaningless. `tmux send-keys -l` against thurbox's own
# socket is the correct primitive and the same one the default tmux backend
# uses.
fm_backend_thurbox_send_literal() {  # <target> <text> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${3:-}" || return 1
  fm_backend_thurbox_tmux send-keys -t "$FM_BACKEND_THURBOX_PANE" -l -- "$2" 2>/dev/null
}

# fm_backend_thurbox_normalize_key: map firstmate's key vocabulary onto tmux's
# key names. thurbox panes are tmux panes, so this is tmux's own vocabulary and
# the identity mapping - kept as an explicit function anyway so the adapter's
# key surface is stated in one place like every other backend's, rather than
# being an implicit consequence of the transport.
fm_backend_thurbox_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'C-c' ;;
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'C-u' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_thurbox_send_key() {  # <target> <key> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_thurbox_normalize_key "$2")
  fm_backend_thurbox_tmux send-keys -t "$FM_BACKEND_THURBOX_PANE" "$key" 2>/dev/null
}

# fm_backend_thurbox_send_text_line: send one line of TEXT then submit. Used for
# the fixed spawn-time commands (`treehouse get`, the GOTMPDIR export), which
# need no composer verification.
fm_backend_thurbox_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_thurbox_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_thurbox_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_thurbox_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_thurbox_capture: bounded PLAIN-text pane capture, for every
# human/LLM-facing path (fm-peek, the watcher's pane tail).
#
# Routed through `thurbox-cli session capture` rather than tmux capture-pane,
# even though both are available: the CLI is thurbox's own supported read
# surface, it honours thurbox's configured scrollback, and it keeps the
# session-level read addressed by the durable UUID. Verified `--lines` bounds
# thurbox's scrollback fetch but the response is not itself trimmed to that
# count, so the result is trimmed locally - the same "fetch generous, trim
# locally" posture herdr and cmux already take for their own reasons.
fm_backend_thurbox_capture() {  # <target> <lines> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} raw out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  raw=$(fm_backend_thurbox_cli session capture "$FM_BACKEND_THURBOX_SESSION" --lines "$lines" --json 2>/dev/null) || return 1
  out=$(printf '%s' "$raw" | jq -r '.output // empty' 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_thurbox_composer_capture: the composer screen WITH ANSI styling,
# read straight off thurbox's tmux socket. thurbox's own `session capture`
# returns plain text only, so the styled read - the thing that lets the shared
# classifier tell a real unsent draft from a styled placeholder - comes from
# tmux, exactly as bin/fm-tmux-lib.sh's fm_tmux_composer_capture does for the
# default backend. Like that function, the styled capture is consumed only by
# the classifier and is NEVER surfaced to a human or an LLM.
fm_backend_thurbox_composer_capture() {  # <target> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${2:-}" || return 1
  fm_backend_thurbox_tmux capture-pane -e -p -t "$FM_BACKEND_THURBOX_PANE" -S 0 -E - 2>/dev/null
}

# fm_backend_thurbox_composer_cursor_row: the pane's zero-based cursor row.
# tmux's genuine primitive, available here for the same reason the styled
# capture is.
fm_backend_thurbox_composer_cursor_row() {  # <target> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${2:-}" || return 1
  fm_backend_thurbox_tmux display-message -p -t "$FM_BACKEND_THURBOX_PANE" '#{cursor_y}' 2>/dev/null
}

# fm_backend_thurbox_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh).
#
# styled=1 and cursor=1 make thurbox the first non-tmux backend to reach the
# default backend's own composer fidelity - both are real tmux primitives
# against thurbox's socket, verified live.
#
# identity=0 deliberately: the pi identity probe in bin/fm-tmux-lib.sh
# (fm_tmux_composer_identity) reads the pane tty's foreground process group via
# the DEFAULT tmux socket, and a thurbox-socket equivalent has not been
# empirically validated. Declaring identity=0 makes the classifier degrade a
# need-identity verdict to `unknown` - the same safe degradation cmux takes -
# rather than have this adapter assert a probe it has not proven.
fm_backend_thurbox_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=0\nrows=0\n'
}

# fm_backend_thurbox_pane_is_cursor: the Cursor-pane probe of
# bin/fm-tmux-lib.sh's fm_tmux_pane_is_cursor, against THURBOX's socket.
#
# Takes a RESOLVED pane id, like fm_backend_thurbox_pane_exists above and
# unlike the target-taking operations: the caller owns resolution, so this
# reads no adapter global and cannot be handed a pane some other call site
# happened to leave behind.
#
# Only the #{pane_tty} read is server-specific, and it is the one thing done
# here; Cursor's process identity stays owned by bin/fm-cursor-lib.sh
# (fm_cursor_tty_has_cursor), so this adapter re-derives none of it.
#
# This is deliberately treated differently from identity=0 above. The pi
# identity probe additionally depends on pi's busy-footer semantics, which have
# had no thurbox pass; Cursor detection is pure foreground-process identity,
# and the only socket-dependent part is the tmux call itself.
fm_backend_thurbox_pane_is_cursor() {  # <pane-id>
  local tty
  tty=$(fm_backend_thurbox_tmux display-message -p -t "$1" '#{pane_tty}' 2>/dev/null) || return 1
  fm_cursor_tty_has_cursor "$tty"
}

# fm_backend_thurbox_composer_state: thin adapter - capture plus cursor plus
# capabilities in, shared verdict out. Every shape, glyph, and border family
# lives in bin/fm-composer-lib.sh, so a new harness shape is taught there once
# and never here.
fm_backend_thurbox_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local target=$1 expected_label=${2:-} cy pane verdict pane_id
  cy=$(fm_backend_thurbox_composer_cursor_row "$target" "$expected_label") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_backend_thurbox_composer_capture "$target" "$expected_label") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_thurbox_composer_caps)" "$pane" "$cy")
  [ "$verdict" != need-identity ] || verdict=unknown
  # Cursor Agent CLI parks its terminal cursor OUTSIDE its composer, below the
  # footer, so on a Cursor pane the cursor row is not a composer locator and
  # the cursor-anchored read can only ever answer `unknown`. cursor=1 buys
  # thurbox tmux's composer fidelity and therefore tmux's Cursor hazard, so it
  # takes tmux's mitigation too (bin/fm-tmux-lib.sh): reclassify that pane the
  # cursorless way, letting the bottom-most shape win, exactly as every
  # cursorless backend already classifies it. Gated on Cursor's own structural
  # process identity, never on the verdict alone, so the strict blank-row
  # posture that owns `unknown` for every other harness is untouched.
  #
  # The pane is resolved HERE, by a direct call in this shell, and handed to
  # the probe as an argument. The two reads above are command substitutions,
  # so the pane target_ready resolved inside each of them died with its
  # subshell; reading that global back here would probe whatever pane the
  # CALLER's shell last resolved - or, in a process that never resolved one
  # (every `set -u` command-substitution call site, which is how the watcher
  # and the doorbell reach this), abort on an unbound variable and silently
  # lose the reclassification entirely.
  if [ "$verdict" = unknown ]; then
    fm_backend_thurbox_target_ready "$target" "$expected_label" || { printf '%s' "$verdict"; return 0; }
    pane_id=$FM_BACKEND_THURBOX_PANE
    if fm_backend_thurbox_pane_is_cursor "$pane_id"; then
      verdict=$(fm_composer_classify_screen "$(fm_backend_thurbox_composer_caps)" "$pane" '')
    fi
  fi
  printf '%s' "$verdict"
}

# fm_backend_thurbox_send_text_submit: type <text> once (raw, unsubmitted), then
# drive the shared verify-and-retry-Enter loop against the shared composer
# verdict. Never retypes. Echoes empty|pending|unknown|send-failed.
#
# The busy-fn argument is what puts thurbox on the queued-Enter conversion tmux
# and herdr have, and it is the only backend on this shared loop that supplies
# one: a harness mid-turn QUEUES the Enter instead of consuming it, so the text
# stays in the composer, every retry reads `pending`, and without the
# conversion fm-send would report an unproven submit and exit nonzero for a
# steer that will in fact land when the turn ends. The signal handed over is
# fm_backend_thurbox_busy_state - thurbox's native hook_state, written by the
# agent's own lifecycle hooks - so only an affirmative `busy` (hook_state
# working) converts: a null hook_state reads unknown and an idle/done/blocked
# reads idle, and neither is accepted as proof of a queue.
#
# NOT empirically verified: unlike everything in this file's findings list,
# this conversion has never been observed against a real mid-turn thurbox
# steer. It is a reasoned extension of the same native signal fm-busy-lib.sh
# already trusts for thurbox, not an observation.
fm_backend_thurbox_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_thurbox_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_thurbox_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_thurbox_send_key fm_backend_thurbox_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label" fm_backend_thurbox_busy_state
}

# fm_backend_thurbox_busy_state: semantic busy/idle/unknown from thurbox's
# NATIVE `hook_state` - the second such reader after herdr, and a real
# agent-state primitive rather than a pane regex.
#
# WHAT THIS ACTUALLY REPORTS TODAY: `unknown`, for a default firstmate-spawned
# session. `hook_state` is written ONLY by `thurbox-cli session signal`, which
# thurbox's own agents invoke from lifecycle hooks thurbox wires when IT
# launches the agent. firstmate's required agents.toml entry is a bare
# interactive shell precisely so firstmate can run treehouse and launch the
# harness itself, so thurbox wires no hooks, and firstmate does not signal
# either. Nothing therefore writes `hook_state` unless the OPERATOR wires
# their harness's own hooks to `thurbox-cli session signal --state <s>` -
# which works with no session argument from inside the pane, because thurbox
# injects THURBOX_SESSION there and child processes inherit it.
#
# This reader is kept, not removed, because it is correct and fails safe: with
# no signal source `hook_state` is null, this returns `unknown`, the widened
# native-busy gate in bin/fm-busy-lib.sh does not fire, and the queued-Enter
# conversion does not convert. It goes live the moment a signal source exists.
# docs/thurbox-backend.md "Active limits" owns the operator-facing statement.
#
# thurbox's agents report their own lifecycle through `thurbox-cli session
# signal --state <working|blocked|done|idle>`, and the state lands on the
# session row. That vocabulary is WORD-FOR-WORD herdr's
# agent_status vocabulary, so the mapping below is herdr's
# (fm_backend_herdr_classify_agent_status) applied unchanged, including
# `blocked` mapping to idle: blocked means the agent is waiting on a human, not
# that a turn is in flight.
#
# `hook_state` is null until an agent first signals (verified on a
# freshly created session), and null classifies as unknown - never idle - so a
# not-yet-reporting session can never be mistaken for a finished one.
fm_backend_thurbox_busy_state() {  # <target> [expected-label]
  fm_backend_thurbox_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  # The row target_ready just resolved is the same row `session get` would
  # return, so it is read rather than fetched a second time - the watcher runs
  # this per task per poll.
  local raw
  raw=$(printf '%s' "$FM_BACKEND_THURBOX_ROW" | jq -r '.hook_state // empty' 2>/dev/null)
  case "$raw" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    blocked) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_thurbox_kill: remove the task's thurbox session, best-effort
# (mirrors every other backend's `kill` `|| true` contract).
#
# --force is mandatory for a headless teardown, not an escalation: the plain
# delete only soft-deletes the database row and leaves window cleanup to the
# TUI's next sync pass (verified, and stated in the CLI's own help), so a
# firstmate teardown with no TUI running would leave the window alive forever.
# --force kills the window, removes worktrees, and cancels pending scheduled
# commands, and reported "killed_window": true in the live pass.
#
# When teardown supplies the expected task label, the resolved ROW's name must
# equal this home's scoped title for it, so a UUID that has been recycled onto
# some other session can never be deleted by mistake.
#
# That identity check reads the session row and deliberately NOT the pane:
# what kill owns is the row, and the row OUTLIVES its window. A pane the
# operator exited, or every pane at once after thurbox's tmux server restarts,
# leaves the row behind - the very state the non-forced delete's soft-delete
# also produces - and gating teardown on pane liveness would leave that row and
# its name reserved forever, so the next spawn of the same task id would hit
# create_task's duplicate refusal permanently.
fm_backend_thurbox_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} expected_title='' name
  fm_backend_thurbox_parse_target "$1" || return 0
  if [ -n "$expected_label" ]; then
    expected_title=$(fm_backend_thurbox_scoped_title "$expected_label" 2>/dev/null) || return 0
    fm_backend_thurbox_resolve_row "$FM_BACKEND_THURBOX_SESSION" "$expected_title" || return 0
    name=$(printf '%s' "$FM_BACKEND_THURBOX_ROW" | jq -r '.name // empty' 2>/dev/null)
    [ "$name" = "$expected_title" ] || return 0
    FM_BACKEND_THURBOX_SESSION=$FM_BACKEND_THURBOX_ROW_UUID
  fi
  fm_backend_thurbox_cli session delete "$FM_BACKEND_THURBOX_SESSION" --force --json >/dev/null 2>&1 || true
}

# fm_backend_thurbox_list_live: recovery/orphan discovery. Lists every live
# session whose NAME is scoped to this firstmate home. One
# "<session_uuid>:<pane_id>\t<fm-id>" line per live task session.
#
# Matching is on the thurbox session NAME, never the tmux window name: thurbox
# prefixes the window ("fm-x" -> "tb-fm-x", finding 3), so the database name is
# the only label authority. Read-only: an unreachable thurbox lists nothing.
# Sessions that are not local-tmux (remote hosts) and rows with no pane yet are
# skipped, since neither can be addressed by this adapter's pane primitives.
fm_backend_thurbox_list_live() {
  local rows uuid name pane btype home prefix plain
  home=$(fm_backend_thurbox_home_label)
  prefix="fm-$home-"
  rows=$(fm_backend_thurbox_cli session list --json 2>/dev/null) || return 0
  while IFS=$'\t' read -r uuid name pane btype; do
    [ -n "$uuid" ] || continue
    [ "$btype" = "local-tmux" ] || continue
    [ -n "$pane" ] || continue
    plain=${name#"$prefix"}
    [ -n "$plain" ] || continue
    printf '%s:%s\tfm-%s\n' "$uuid" "$pane" "$plain"
  done < <(printf '%s' "$rows" | jq -r --arg prefix "$prefix" '.[]? | select(.name | startswith($prefix)) | "\(.id)\t\(.name)\t\(.backend_id // "")\t\(.backend_type // "")"' 2>/dev/null)
}
