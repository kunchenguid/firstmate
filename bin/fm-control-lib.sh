#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|muse|cursor) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# and an unrecognized value returns nonzero rather than being guessed into a
# family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    muse*) printf 'muse' ;;
    cursor|cursor-agent) printf 'cursor' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse and cursor are
# crewmate/scout adapters only: neither has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on them. The control plane
# asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|cursor) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok and
# cursor, whose TUIs advertise Ctrl+C as the cancel control (verified: cursor
# footer shows "ctrl+c to stop"; Escape can also cancel but Ctrl+C is the
# documented path).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|kimi|muse) printf 'Escape' ;;
    grok|cursor) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|grok|kimi|muse|cursor) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. Prints the key or nothing; a harness with no verified
# mechanics returns nonzero, matching the tables above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|muse|cursor) printf '/exit' ;;
    codex|pi|pi-signed) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
  esac
}

fm_control_cursor_hooks_backup() {  # <worktree> <state-dir> <id> [reuse]
  local wt=$1 state=$2 id=$3 reuse=${4:-} path backup installed next retained=0 cursor_dir="$1/.cursor" hooks_dir="$1/.cursor/hooks"
  [ ! -L "$cursor_dir" ] && [ ! -L "$hooks_dir" ] || return 1
  [ ! -e "$cursor_dir" ] || [ -d "$cursor_dir" ] || return 1
  [ ! -e "$hooks_dir" ] || [ -d "$hooks_dir" ] || return 1
  for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
      return 1
    fi
    backup="$state/$id.cursor-$(basename "$path")"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
      retained=1
    fi
    installed="$state/$id.cursor-$(basename "$path").installed"
    if [ -e "$installed" ] || [ -L "$installed" ]; then
      [ -f "$installed" ] && [ ! -L "$installed" ] || return 1
      retained=1
    fi
  done
  if [ "$retained" -eq 1 ]; then
    [ "$reuse" = reuse ] || return 1
    for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
      installed="$state/$id.cursor-$(basename "$path").installed"
      [ -f "$installed" ] && [ ! -L "$installed" ] || return 1
      backup="$state/$id.cursor-$(basename "$path")"
      next="$backup.next.$$"
      [ ! -e "$next" ] && [ ! -L "$next" ] || return 1
    done
    for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
      [ -e "$path" ] || continue
      backup="$state/$id.cursor-$(basename "$path")"
      next="$backup.next.$$"
      cp -p -- "$path" "$next" || {
        rm -f -- "$state/$id.cursor-hooks.json.next.$$" \
          "$state/$id.cursor-fm-busy-turnend.sh.next.$$"
        return 1
      }
    done
    for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
      backup="$state/$id.cursor-$(basename "$path")"
      next="$backup.next.$$"
      if [ -e "$path" ]; then
        mv -f -- "$next" "$backup" || return 1
      else
        rm -f -- "$backup" || return 1
      fi
    done
    return 0
  fi
  for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
    [ -e "$path" ] || continue
    backup="$state/$id.cursor-$(basename "$path")"
    cp -p -- "$path" "$backup" || {
      rm -f -- "$state/$id.cursor-hooks.json" "$state/$id.cursor-fm-busy-turnend.sh"
      return 1
    }
  done
}

fm_control_cursor_hooks_record_installed() {  # <worktree> <state-dir> <id> <hooks-json> <hook-script>
  local wt=$1 state=$2 id=$3 hooks_source=$4 script_source=$5 path source installed
  [ ! -L "$wt/.cursor" ] && [ ! -L "$wt/.cursor/hooks" ] || return 1
  for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
    case "$(basename "$path")" in
      hooks.json) source=$hooks_source ;;
      fm-busy-turnend.sh) source=$script_source ;;
    esac
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    installed="$state/$id.cursor-$(basename "$path").installed"
    if [ -e "$installed" ] || [ -L "$installed" ]; then
      [ -f "$installed" ] && [ ! -L "$installed" ] || return 1
    fi
    cp -p -- "$source" "$installed" || return 1
  done
}

fm_control_cursor_hooks_transaction_present() {  # <state-dir> <id>
  local state=$1 id=$2 path
  for path in \
    "$state/$id.cursor-hooks.json" \
    "$state/$id.cursor-fm-busy-turnend.sh" \
    "$state/$id.cursor-hooks.json.installed" \
    "$state/$id.cursor-fm-busy-turnend.sh.installed"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
  done
  return 1
}

fm_control_cursor_hooks_forget() {  # <state-dir> <id>
  local state=$1 id=$2
  rm -f -- "$state/$id.cursor-hooks.json" "$state/$id.cursor-fm-busy-turnend.sh" \
    "$state/$id.cursor-hooks.json.installed" "$state/$id.cursor-fm-busy-turnend.sh.installed"
}

fm_control_cursor_hook_path_matches_installed() {  # <worktree> <state-dir> <id> <relative-path>
  local wt=$1 state=$2 id=$3 relative=$4 installed backup
  case "$relative" in
    .cursor/hooks.json|.cursor/hooks/fm-busy-turnend.sh) ;;
    *) return 1 ;;
  esac
  installed="$state/$id.cursor-$(basename "$relative").installed"
  [ -f "$installed" ] && [ ! -L "$installed" ] \
    && [ -f "$wt/$relative" ] && [ ! -L "$wt/$relative" ] \
    && cmp -s "$wt/$relative" "$installed" || return 1
  backup="$state/$id.cursor-$(basename "$relative")"
  if git -C "$wt" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
    [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
    git -C "$wt" show ":$relative" | cmp -s "$backup" -
  else
    [ ! -e "$backup" ] && [ ! -L "$backup" ]
  fi
}

fm_control_cursor_hook_path_is_teardown_safe() {  # <worktree> <state-dir> <id> <relative-path>
  local wt=$1 state=$2 id=$3 relative=$4 installed backup
  case "$relative" in
    .cursor/hooks.json|.cursor/hooks/fm-busy-turnend.sh) ;;
    *) return 1 ;;
  esac
  installed="$state/$id.cursor-$(basename "$relative").installed"
  [ -f "$installed" ] && [ ! -L "$installed" ] || return 1
  if fm_control_cursor_hook_path_matches_installed "$wt" "$state" "$id" "$relative"; then
    return 0
  fi
  backup="$state/$id.cursor-$(basename "$relative")"
  if git -C "$wt" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
    [ -f "$backup" ] && [ ! -L "$backup" ] \
      && [ -f "$wt/$relative" ] && [ ! -L "$wt/$relative" ] \
      && git -C "$wt" show ":$relative" | cmp -s "$backup" - \
      && cmp -s "$wt/$relative" "$backup"
  else
    [ ! -e "$backup" ] && [ ! -L "$backup" ] \
      && [ ! -e "$wt/$relative" ] && [ ! -L "$wt/$relative" ]
  fi
}

fm_control_cursor_hooks_restore() {  # <worktree> <state-dir> <id>
  local wt=$1 state=$2 id=$3 path backup installed cursor_dir="$1/.cursor" hooks_dir="$1/.cursor/hooks"
  [ ! -L "$cursor_dir" ] && [ ! -L "$hooks_dir" ] || return 1
  [ ! -e "$cursor_dir" ] || [ -d "$cursor_dir" ] || return 1
  [ ! -e "$hooks_dir" ] || [ -d "$hooks_dir" ] || return 1
  for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
    [ ! -L "$path" ] || return 1
    [ ! -e "$path" ] || [ -f "$path" ] || return 1
    if [ "$(basename "$path")" = hooks.json ]; then
      backup="$state/$id.cursor-hooks.json"
    else
      backup="$state/$id.cursor-fm-busy-turnend.sh"
    fi
    installed="$state/$id.cursor-$(basename "$path").installed"
    [ ! -e "$backup" ] || { [ -f "$backup" ] && [ ! -L "$backup" ]; } || return 1
    [ -f "$installed" ] && [ ! -L "$installed" ] || return 1
  done
  for path in "$wt/.cursor/hooks.json" "$wt/.cursor/hooks/fm-busy-turnend.sh"; do
    if [ "$(basename "$path")" = hooks.json ]; then
      backup="$state/$id.cursor-hooks.json"
    else
      backup="$state/$id.cursor-fm-busy-turnend.sh"
    fi
    installed="$state/$id.cursor-$(basename "$path").installed"
    if [ ! -e "$path" ]; then
      if [ -e "$backup" ]; then
        cp -p -- "$backup" "$path" || return 1
      fi
    elif cmp -s "$path" "$installed"; then
      if [ -e "$backup" ]; then
        cp -p -- "$backup" "$path" || return 1
      else
        rm -f -- "$path" || return 1
      fi
    elif [ "$(basename "$path")" = hooks.json ] && [ -f "$path" ]; then
      python3 - "$path" "$backup" <<'PY' || return 1
import json
import os
import sys
import tempfile

path, backup_path = sys.argv[1:]
expected = {
    "beforeSubmitPrompt": ".cursor/hooks/fm-busy-turnend.sh busy",
    "stop": ".cursor/hooks/fm-busy-turnend.sh idle-stop",
    "sessionEnd": ".cursor/hooks/fm-busy-turnend.sh idle-session-end",
}
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
hooks = document.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit("Cursor hooks must be a JSON object")
backup_hooks = {}
if os.path.exists(backup_path):
    with open(backup_path, encoding="utf-8") as handle:
        backup = json.load(handle)
    backup_hooks = backup.get("hooks")
    if not isinstance(backup_hooks, dict):
        raise SystemExit("Backed-up Cursor hooks must be a JSON object")
for event, entries in hooks.items():
    if not isinstance(entries, list):
        raise SystemExit(f"Cursor {event} hooks must be arrays")
changed = False
expected_event = {command: event for event, command in expected.items()}
removals = {}
for event, entries in hooks.items():
    original_entries = backup_hooks.get(event, [])
    if not isinstance(original_entries, list):
        raise SystemExit(f"Backed-up Cursor {event} hooks must be arrays")
    unmatched_original = list(original_entries)
    for index, entry in enumerate(entries):
        try:
            original_index = unmatched_original.index(entry)
        except ValueError:
            if not isinstance(entry, dict):
                continue
            command = entry.get("command")
            owner_event = expected_event.get(command)
            if owner_event is None:
                continue
            if event != owner_event or entry != {"command": command}:
                raise SystemExit(f"Cannot safely reconcile generated Cursor {event} hook")
            removals.setdefault(event, []).append(index)
        else:
            del unmatched_original[original_index]
for event, indices in removals.items():
    if len(indices) != 1:
        raise SystemExit(f"Cannot safely reconcile generated Cursor {event} hook")
    del hooks[event][indices[0]]
    changed = True
if changed:
    directory = os.path.dirname(path)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=directory, delete=False) as handle:
        json.dump(document, handle, separators=(",", ":"))
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, path)
PY
    elif [ "$(basename "$path")" = fm-busy-turnend.sh ]; then
      if [ -e "$backup" ]; then
        cp -p -- "$backup" "$path" || return 1
      else
        return 1
      fi
    fi
  done
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
