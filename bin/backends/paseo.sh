#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo agent-session-provider adapter (EXPERIMENTAL).
#
# Empirical basis: docs/paseo-backend.md (verified against the real installed
# CLI, Paseo v0.1.104, daemon on 127.0.0.1:6767). Read that doc before changing
# any command below; it records the exact commands run and their exact output.
#
# Paseo (paseo.sh, getpaseo/paseo) is a self-hosted TypeScript daemon that
# manages headless coding-agent sessions and exposes them in desktop/mobile/web
# clients. Unlike tmux/herdr/zellij/cmux, Paseo is NOT a terminal multiplexer:
# there is no pane to type into. `paseo run` LAUNCHES the provider agent
# directly with a prompt and a --cwd, and `paseo send` delivers a follow-up
# MESSAGE to that agent over the daemon API. So this adapter has no
# type-then-submit composer dance: a steer is one atomic `paseo send --no-wait`.
#
# Worktree ownership stays with treehouse, exactly like tmux/herdr (NOT like
# Orca, which owns its own worktree). fm-spawn.sh leases a treehouse worktree
# non-interactively (`treehouse get --lease`) and passes it to `paseo run --cwd`;
# Paseo's own `paseo worktree` feature is never used. Teardown returns that lease
# through the standard treehouse-return path in fm-teardown.sh.
#
# Target string shape: the Paseo agent id (a UUID). A task's meta records
# `backend=paseo` and `paseo_agent_id=<uuid>`; `window=fm-<id>` is kept only as
# a human-facing display alias (fm_backend_target_of_meta resolves paseo tasks
# to the agent id, mirroring how it resolves orca tasks to `terminal=`).
#
# Gating: selectable ONLY via explicit `--backend paseo` / `FM_BACKEND=paseo` /
# `config/backend` - never runtime auto-detected (the zellij/orca precedent),
# even though firstmate itself commonly runs AS a Paseo agent. Spawn refuses
# grok (not a Paseo provider) and refuses --secondmate (out of scope initially).
#
# Requires: paseo (CLI + running daemon) and node (JSON parsing; a universal
# firstmate requirement already). Both are gated behind selecting this backend;
# bin/fm-bootstrap.sh's core tool list is unaffected (the version/daemon/provider
# gate happens at spawn time instead).

# The verified CLI floor. Paseo is pre-1.0 and its --json shapes are still
# moving, so the floor is pinned to the exact verified version rather than a
# looser range: every command and JSON field below was verified against
# v0.1.104 only (docs/paseo-backend.md). Raise this only after re-verifying
# against the newer build.
FM_BACKEND_PASEO_MIN_VERSION="0.1.104"

# fm_backend_paseo_bin: the paseo binary. ~/.local/bin is where the verified
# install lives but is not always on a non-interactive PATH, so fall back to it.
fm_backend_paseo_bin() {
  if command -v paseo >/dev/null 2>&1; then
    printf 'paseo'
    return 0
  fi
  if [ -x "$HOME/.local/bin/paseo" ]; then
    printf '%s' "$HOME/.local/bin/paseo"
    return 0
  fi
  return 1
}

fm_backend_paseo_tool_check() {
  fm_backend_paseo_bin >/dev/null || { echo "error: backend=paseo selected but the 'paseo' CLI is not installed (https://paseo.sh)" >&2; return 1; }
  command -v node >/dev/null 2>&1 || { echo "error: backend=paseo selected but 'node' is not installed (required to parse paseo's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_paseo_cli: run the paseo binary, resolving it once per call.
fm_backend_paseo_cli() {  # <paseo-args...>
  local bin
  bin=$(fm_backend_paseo_bin) || return 1
  "$bin" "$@"
}

# fm_backend_paseo_json_field: read one top-level scalar <field> from a paseo
# --json object on stdin, or exit non-zero if absent. Mirrors orca.sh's
# node-based JSON reader (node is the universal firstmate JSON tool here).
fm_backend_paseo_json_field() {  # <field>  (json on stdin)
  node -e '
const fs = require("fs");
const field = process.argv[1];
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { process.exit(2); }
const v = data && data[field];
if (v === undefined || v === null || v === "") process.exit(1);
process.stdout.write(String(v));
' "$1"
}

# fm_backend_paseo_version_ge: is <have> >= <want>, numeric dotted compare.
fm_backend_paseo_version_ge() {  # <have> <want>
  node -e '
const a = String(process.argv[1]).split(".").map(n => parseInt(n, 10) || 0);
const b = String(process.argv[2]).split(".").map(n => parseInt(n, 10) || 0);
const len = Math.max(a.length, b.length);
for (let i = 0; i < len; i++) {
  const x = a[i] || 0, y = b[i] || 0;
  if (x > y) process.exit(0);
  if (x < y) process.exit(1);
}
process.exit(0);
' "$1" "$2"
}

# fm_backend_paseo_runtime_check: refuse loudly unless the paseo CLI, node, a
# running/reachable daemon, and a new-enough CLI are all present. `paseo status
# --json` reports localDaemon/connectedDaemon and cliVersion (verified
# docs/paseo-backend.md).
fm_backend_paseo_runtime_check() {
  fm_backend_paseo_tool_check || return 1
  # `st`, not `status`: `status` is a read-only special variable in zsh, which
  # can source this file (fm-backend.sh header).
  local st local_d conn_d version
  st=$(fm_backend_paseo_cli status --json 2>/dev/null) || { echo "error: 'paseo status --json' failed; is the Paseo daemon running? (paseo start)" >&2; return 1; }
  local_d=$(printf '%s' "$st" | fm_backend_paseo_json_field localDaemon 2>/dev/null || true)
  conn_d=$(printf '%s' "$st" | fm_backend_paseo_json_field connectedDaemon 2>/dev/null || true)
  if [ "$local_d" != running ] && [ "$conn_d" != reachable ]; then
    echo "error: the Paseo daemon is not running/reachable (localDaemon=${local_d:-unknown}, connectedDaemon=${conn_d:-unknown}); start it with 'paseo start'" >&2
    return 1
  fi
  version=$(printf '%s' "$st" | fm_backend_paseo_json_field cliVersion 2>/dev/null || true)
  if [ -z "$version" ]; then
    echo "error: could not read Paseo cliVersion from 'paseo status --json'; refusing to use an unverified Paseo build" >&2
    return 1
  fi
  if ! fm_backend_paseo_version_ge "$version" "$FM_BACKEND_PASEO_MIN_VERSION"; then
    echo "error: Paseo CLI $version is older than the verified minimum $FM_BACKEND_PASEO_MIN_VERSION; update paseo before using backend=paseo" >&2
    return 1
  fi
  return 0
}

# fm_backend_paseo_provider_for_harness: map a firstmate harness to a Paseo
# provider name, refusing a harness Paseo cannot launch. grok is NOT a Paseo
# provider (verified: `paseo provider ls` lists claude/codex/opencode/pi as
# available, plus copilot/omp; no grok), so a grok crewmate on this backend is
# refused loudly rather than silently mis-launched.
fm_backend_paseo_provider_for_harness() {  # <harness>
  case "$1" in
    claude|codex|opencode|pi) printf '%s' "$1"; return 0 ;;
    grok) echo "error: backend=paseo cannot launch harness 'grok' (grok is not a Paseo provider); use --backend tmux for grok, or a Paseo-supported harness (claude, codex, opencode, pi)" >&2; return 1 ;;
    *) echo "error: backend=paseo does not support harness '$1' (Paseo providers: claude, codex, opencode, pi)" >&2; return 1 ;;
  esac
}

# fm_backend_paseo_run: launch the agent. Echoes the new agent id on success.
# The prompt is the brief's CONTENT (Paseo takes the initial task as the run
# prompt, not a shell launch command). --mode bypassPermissions is the
# autonomous-crewmate equivalent of claude's --dangerously-skip-permissions
# (verified mode id for claude; docs/paseo-backend.md). --label fm-task=<id>
# tags the agent for label-based lookup; --title fm-<id> is the human-facing
# name shown in the Paseo app. GOTMPDIR rides --env (Paseo has no pane to
# `export` into).
fm_backend_paseo_run() {  # <cwd> <provider> <model> <title> <label-id> <gotmpdir> <brief-path>
  local cwd=$1 provider=$2 model=$3 title=$4 label_id=$5 gotmpdir=$6 brief=$7 spec out agent_id
  spec=$provider
  if [ -n "$model" ] && [ "$model" != default ]; then
    spec="$provider/$model"
  fi
  out=$(fm_backend_paseo_cli run --detach --cwd "$cwd" --provider "$spec" \
    --mode bypassPermissions --title "$title" --label "fm-task=$label_id" \
    --env "GOTMPDIR=$gotmpdir" --json "$(cat "$brief")" 2>/dev/null) || {
    echo "error: 'paseo run' failed for $title (provider $spec, cwd $cwd)" >&2
    return 1
  }
  agent_id=$(printf '%s' "$out" | fm_backend_paseo_json_field agentId 2>/dev/null) || {
    echo "error: 'paseo run' did not return an agentId for $title" >&2
    return 1
  }
  printf '%s' "$agent_id"
}

# fm_backend_paseo_status_raw: the raw agent status string (running/idle/...),
# or empty when the agent is not found or unreadable. `paseo inspect --json`
# reports it as PascalCase `Status` (verified); a not-found agent yields an
# `{error:...}` body and a non-zero exit.
fm_backend_paseo_status_raw() {  # <agent-id>
  local out
  out=$(fm_backend_paseo_cli inspect "$1" --json 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | fm_backend_paseo_json_field Status 2>/dev/null || printf ''
}

# fm_backend_paseo_capture: bounded activity read. Paseo's timeline is
# `paseo logs --tail N` (not a raw terminal scrollback); it is the closest
# analogue to tmux's capture-pane for a message-based agent.
fm_backend_paseo_capture() {  # <agent-id> <lines>
  local id=$1 lines=${2:-40}
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fm_backend_paseo_cli logs "$id" --tail "$lines" 2>/dev/null || return 1
}

# fm_backend_paseo_send_text_submit: deliver <text> to the agent as one atomic
# message. Paseo's API delivers it in a single call (no composer to submit, no
# autocomplete-popup hazard), so this ignores the tmux-style retries/sleeps and
# reports the shared "empty" verdict ("confirmed submitted") on success. The
# extra positional args exist only to match the generic dispatcher signature.
fm_backend_paseo_send_text_submit() {  # <agent-id> <text> [retries] [enter-sleep] [settle]
  local id=$1 text=$2
  if fm_backend_paseo_cli send "$id" --no-wait --prompt "$text" >/dev/null 2>&1; then
    printf 'empty'
  else
    printf 'send-failed'
  fi
}

# fm_backend_paseo_send_key: Paseo is message-based, so most "keys" have no
# meaning. C-c maps to `paseo stop` (interrupt a running agent). Enter is a
# no-op success (a message is already delivered atomically by send). Escape is
# unsupported (the Orca precedent), refused loudly.
fm_backend_paseo_send_key() {  # <agent-id> <key>
  local id=$1 key=$2
  case "$key" in
    C-c|c-c|ctrl+c|Ctrl+C|Ctrl-c|Ctrl-C)
      fm_backend_paseo_cli stop "$id" >/dev/null 2>&1 || true
      ;;
    Enter|enter)
      : # no-op: send delivers the message atomically, there is no pending composer to submit
      ;;
    Escape|escape|Esc|esc)
      echo "error: backend=paseo does not support the Escape key (no terminal composer)" >&2
      return 1
      ;;
    *)
      echo "error: backend=paseo does not support key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_paseo_kill: hard-delete the agent, best-effort (mirrors tmux
# kill-window's `|| true` contract). `paseo delete` interrupts a running agent
# then removes its record; deleting an already-gone agent is a harmless no-op
# for teardown's purposes.
fm_backend_paseo_kill() {  # <agent-id> [ignored...]
  [ -n "${1:-}" ] || return 0
  fm_backend_paseo_cli delete "$1" >/dev/null 2>&1 || true
}

# fm_backend_paseo_busy_state: semantic busy state from Paseo's native agent
# status. running -> busy (actively working a turn); idle -> idle; anything
# else/unreadable -> unknown (the caller's cue to fall back to its own policy).
fm_backend_paseo_busy_state() {  # <agent-id>
  case "$(fm_backend_paseo_status_raw "$1")" in
    running) printf 'busy' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_paseo_agent_alive: CONFIDENT liveness for the session-start
# secondmate-liveness sweep and recovery digests (fm_backend_agent_alive
# dispatcher). running/idle are both a live registered agent -> alive; a
# not-found agent -> dead (its record is gone); error/closed -> dead; anything
# unreadable -> unknown (never treated as confirmed-dead - fail safe toward
# refusal, exactly like the tmux/herdr probes).
#
# NOTE: no local variable is named `status` - it is a read-only special
# variable in zsh, and this file can be sourced by a zsh diagnostic
# (fm-backend.sh header), where `local status` would hard-error.
fm_backend_paseo_agent_alive() {  # <agent-id>
  local out code msg st
  out=$(fm_backend_paseo_cli inspect "$1" --json 2>&1) || {
    code=$(printf '%s' "$out" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write((d.error&&d.error.code)||"")}catch(e){}' 2>/dev/null || true)
    msg=$(printf '%s' "$out" | node -e 'try{const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write((d.error&&d.error.message)||"")}catch(e){}' 2>/dev/null || true)
    case "$msg" in
      *"not found"*|*"Not found"*|*"NOT_FOUND"*) printf 'dead'; return 0 ;;
    esac
    case "$code" in
      *NOT_FOUND*) printf 'dead'; return 0 ;;
    esac
    printf 'unknown'
    return 0
  }
  st=$(printf '%s' "$out" | fm_backend_paseo_json_field Status 2>/dev/null || true)
  case "$st" in
    running|idle) printf 'alive' ;;
    error|closed|failed|stopped) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_paseo_target_exists: cheap read-only presence check - does the
# recorded agent id still exist? A successful `paseo inspect` means yes.
fm_backend_paseo_target_exists() {  # <agent-id>
  [ -n "${1:-}" ] || return 1
  fm_backend_paseo_cli inspect "$1" --json >/dev/null 2>&1
}
