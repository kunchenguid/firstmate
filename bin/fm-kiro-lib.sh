#!/usr/bin/env bash
# fm-kiro-lib.sh - Kiro CLI home and project-scoped configuration owner.
#
# Kiro CLI V3 resolves custom agents and expanded hooks from the current
# project's .kiro/ tree.
# KIRO_HOME still owns Firstmate's settings, data, and logs, but KAS 0.66.4
# (kiro-cli 2.22.1) can also discover the operator's global ~/.kiro
# configuration even when KIRO_HOME is set, and it persists V3 conversations
# under the login HOME's ~/.kiro/sessions, so a plain `kiro-cli --resume-id`
# reopens a Firstmate session without any of its launcher environment.
# Firstmate therefore uses both boundaries together:
#   - an isolated KIRO_HOME with chat.enableKnowledge=false;
#   - a task-specific project agent with the knowledge tool excluded, Powers
#     disabled, and capability `all` explicitly allowed for unattended work;
#   - task-specific project lifecycle hooks whose command names the tracked
#     adapter by the absolute path of this library's own bin directory and
#     passes the task's absolute KIRO_HOME, so a hook reaches its task from any
#     folder and without launcher environment (a session resumed with plain
#     kiro-cli carries neither).
#
# V2 remains an explicit compatibility fallback only.
# Its legacy embedded-hook agent receives a distinct name, so the V3 project
# agent can never shadow it when an operator deliberately selects V2.
#
# Generated project files are task-specific and idempotent by exact bytes.
# The Kiro workspace bridge is a regular copy of the isolated-home payload.
# An existing different file, symlink, symlinked configuration directory, or
# unsafe destination refuses rather than overwriting project-owned material.
# Callers add the generated paths to git's per-worktree exclude and retire them
# through fm_control_harness_wiring_paths.
#
# Sourced by fm-spawn.sh, fm-control-lib.sh, fm-teardown.sh, and the primary
# launcher.

FM_KIRO_V3_AGENT_PREFIX=firstmate-kiro
FM_KIRO_V2_AGENT_PREFIX=firstmate-kiro-v2
FM_KIRO_V3_HOOK_PREFIX=fm-firstmate

fm_kiro_slug_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_kiro_v3_agent_name() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '%s-%s' "$FM_KIRO_V3_AGENT_PREFIX" "$1"
}

fm_kiro_v2_agent_name() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '%s-%s' "$FM_KIRO_V2_AGENT_PREFIX" "$1"
}

fm_kiro_v3_agent_relpath() {  # <task-id>
  printf '.kiro/agents/%s.json' "$(fm_kiro_v3_agent_name "$1")"
}

fm_kiro_v3_hook_relpath() {  # <task-id>
  fm_kiro_slug_valid "$1" || return 1
  printf '.kiro/hooks/%s-%s.json' "$FM_KIRO_V3_HOOK_PREFIX" "$1"
}

fm_kiro_v3_agent_path() {  # <workspace> <task-id>
  printf '%s/%s' "${1%/}" "$(fm_kiro_v3_agent_relpath "$2")"
}

fm_kiro_v3_hook_path() {  # <workspace> <task-id>
  printf '%s/%s' "${1%/}" "$(fm_kiro_v3_hook_relpath "$2")"
}

fm_kiro_v3_agent_home_path() {  # <kiro-home> <task-id>
  printf '%s/project/.kiro/agents/%s.json' "${1%/}" "$(fm_kiro_v3_agent_name "$2")"
}

fm_kiro_v3_hook_home_path() {  # <kiro-home> <task-id>
  printf '%s/project/.kiro/hooks/%s-%s.json' "${1%/}" "$FM_KIRO_V3_HOOK_PREFIX" "$2"
}

fm_kiro_safe_dir() {  # <dir>
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ]
    return
  fi
  mkdir "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

fm_kiro_prepare_home() {  # <kiro-home>
  local home=$1
  [ -n "$home" ] || return 1
  fm_kiro_safe_dir "$home" || return 1
  fm_kiro_safe_dir "$home/settings" || return 1
  fm_kiro_safe_dir "$home/agents" || return 1
  fm_kiro_safe_dir "$home/data" || return 1
}

fm_kiro_publish_owned() {  # <destination>, content on stdin
  local dest=$1 parent tmp
  parent=${dest%/*}
  fm_kiro_safe_dir "$parent" || return 1
  tmp=$(mktemp "$parent/.fm-kiro.XXXXXXXXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  [ -f "$dest" ] && [ ! -L "$dest" ]
}

fm_kiro_publish_project_copy() {  # <destination> <source>
  local dest=$1 source=$2 parent tmp
  parent=${dest%/*}
  fm_kiro_safe_dir "$parent" || return 1
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -L "$dest" ] || return 1
  if [ -e "$dest" ]; then
    [ -f "$dest" ] && cmp -s "$dest" "$source" || return 1
  fi
  tmp=$(mktemp "$parent/.fm-kiro.XXXXXXXXXXXX") || return 1
  if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  [ -f "$dest" ] && [ ! -L "$dest" ]
}

# The tracked lifecycle-hook adapter, resolved once from this library's own
# directory. Every generated hook command names it by this absolute path.
FM_KIRO_TURNEND_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-kiro-turnend-hook.sh"

fm_kiro_shell_quote() {  # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Print <value> as a JSON string body. Control characters refuse rather than
# producing a hook document Kiro would reject or misread.
fm_kiro_json_string() {  # <value>
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Print the hook command for one task's generated V3 hook file or V2 agent.
# The per-task KIRO_HOME is the only binding a resumed session needs: it holds
# the turn-end pointer, the registry, and the session record from which
# bin/fm-kiro-turnend-hook.sh recovers the busy generation.
fm_kiro_task_hook_command() {  # <kiro-home>
  case "$1" in /*) ;; *) return 1 ;; esac
  printf '%s --kiro-home %s' "$(fm_kiro_shell_quote "$FM_KIRO_TURNEND_HOOK")" "$(fm_kiro_shell_quote "${1%/}")"
}

# Print the hook command for the explicit V2 primary agent, which lives in the
# per-home isolated KIRO_HOME rather than in the tracked project hooks.
fm_kiro_primary_hook_command() {
  printf 'FM_KIRO_PRIMARY_HOOK=1 %s' "$(fm_kiro_shell_quote "$FM_KIRO_TURNEND_HOOK")"
}

fm_kiro_write_settings() {  # <kiro-home>
  local home=$1
  fm_kiro_prepare_home "$home" || return 1
  fm_kiro_publish_owned "$home/settings/cli.json" <<'EOF'
{
  "chat.disableTrustAllConfirmation": true,
  "chat.allowAnimations": false,
  "chat.enableKnowledge": false
}
EOF
}

fm_kiro_write_v2_agent() {  # <kiro-home> <agent-name> <hook-command>
  local home=$1 agent=$2 command
  fm_kiro_slug_valid "$agent" || return 1
  command=$(fm_kiro_json_string "$3") || return 1
  fm_kiro_prepare_home "$home" || return 1
  fm_kiro_publish_owned "$home/agents/$agent.json" <<EOF
{
  "name": "$agent",
  "description": "Firstmate-owned Kiro CLI V2 compatibility agent.",
  "tools": ["*"],
  "allowedTools": ["*"],
  "hooks": {
    "userPromptSubmit": [
      { "command": "$command" }
    ],
    "preToolUse": [
      { "command": "$command" }
    ],
    "postToolUse": [
      { "command": "$command" }
    ],
    "stop": [
      { "command": "$command" }
    ]
  }
}
EOF
}

# The concrete V3 tool set, declared once. Kiro's `allowedTools` grants no
# useful wildcard: an agent declaring ["*"] reads files and runs shell without
# asking, yet still stops on fs_write's Replace in File with a human approval
# dialog, which stalled two scouts on 2026-09-21. A concrete list is what the
# operator's own working agents carry and what `kiro-cli agent validate`
# accepts. The tracked .kiro/agents/firstmate-kiro.json carries the same list
# for the primary; tests/fm-kiro-harness.test.sh pins the two equal and
# wildcard-free.
FM_KIRO_V3_TOOLS_JSON='["execute_bash", "fs_read", "fs_write", "code", "grep", "glob", "web_fetch", "web_search", "introspect", "session", "report", "tool_search"]'

fm_kiro_install_v3_project_config() {  # <workspace> <task-id> <kiro-home>
  local workspace=$1 id=$2 home=$3 agent agent_path hook_path agent_home hook_home command
  [ -d "$workspace" ] && [ ! -L "$workspace" ] || return 1
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  fm_kiro_slug_valid "$id" || return 1
  command=$(fm_kiro_task_hook_command "$home") || return 1
  command=$(fm_kiro_json_string "$command") || return 1
  fm_kiro_safe_dir "$workspace/.kiro" || return 1
  fm_kiro_safe_dir "$workspace/.kiro/agents" || return 1
  fm_kiro_safe_dir "$workspace/.kiro/hooks" || return 1
  fm_kiro_safe_dir "$home/project" || return 1
  fm_kiro_safe_dir "$home/project/.kiro" || return 1
  fm_kiro_safe_dir "$home/project/.kiro/agents" || return 1
  fm_kiro_safe_dir "$home/project/.kiro/hooks" || return 1
  agent=$(fm_kiro_v3_agent_name "$id") || return 1
  agent_path=$(fm_kiro_v3_agent_path "$workspace" "$id") || return 1
  hook_path=$(fm_kiro_v3_hook_path "$workspace" "$id") || return 1
  agent_home=$(fm_kiro_v3_agent_home_path "$home" "$id") || return 1
  hook_home=$(fm_kiro_v3_hook_home_path "$home" "$id") || return 1
  fm_kiro_publish_owned "$agent_home" <<EOF || return 1
{
  "name": "$agent",
  "description": "Firstmate-owned Kiro CLI V3 worker agent.",
  "prompt": "Follow the active Firstmate task or secondmate instructions exactly.",
  "tools": $FM_KIRO_V3_TOOLS_JSON,
  "allowedTools": $FM_KIRO_V3_TOOLS_JSON,
  "excludedTools": ["knowledge"],
  "includeMcpJson": true,
  "includePowers": false,
  "permissions": {
    "rules": [
      { "capability": "all", "effect": "allow" }
    ]
  }
}
EOF
  fm_kiro_publish_owned "$hook_home" <<EOF || return 1
{
  "version": "v1",
  "hooks": [
    {
      "name": "firstmate-prompt-submit",
      "trigger": "UserPromptSubmit",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-pre-tool",
      "trigger": "PreToolUse",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-post-tool",
      "trigger": "PostToolUse",
      "action": {
        "type": "command",
        "command": "$command"
      }
    },
    {
      "name": "firstmate-stop",
      "trigger": "Stop",
      "action": {
        "type": "command",
        "command": "$command"
      }
    }
  ]
}
EOF
  fm_kiro_publish_project_copy "$agent_path" "$agent_home" || return 1
  fm_kiro_publish_project_copy "$hook_path" "$hook_home" || return 1
}

fm_kiro_remove_v3_project_config() {  # <workspace> <task-id>
  local workspace=$1 id=$2 agent_path hook_path
  agent_path=$(fm_kiro_v3_agent_path "$workspace" "$id") || return 1
  hook_path=$(fm_kiro_v3_hook_path "$workspace" "$id") || return 1
  rm -f -- "$agent_path" "$hook_path" || return 1
  rmdir "$workspace/.kiro/agents" "$workspace/.kiro/hooks" "$workspace/.kiro" 2>/dev/null || true
}

# Build the firstmate-owned isolated KIRO_HOME for ONE task and print the
# turn-end token it registered:
#   settings/cli.json          - chat.disableTrustAllConfirmation=true (suppress
#                                the --trust-all-tools startup dialog, VERIFIED
#                                LIVE to otherwise render with its default on
#                                "No, exit" and block the launch) and
#                                chat.allowAnimations=false (freeze the spinner
#                                to one static frame for a stable screen-scrape
#                                baseline);
#   agents/<v2-agent>.json     - the explicit V2 fallback's embedded-hook agent,
#                                only when a V2 agent name is given;
#   agents/fm-turn-end.d/<tok> - this task's registry entry naming
#                                state/<id>.turn-ended;
#   .fm-kiro-turnend           - the pointer carrying <tok>. The shared hook
#                                touches the registered file only when both
#                                agree, so a stray kiro-cli session under this
#                                KIRO_HOME that is not this task changes nothing
#                                (the grok/kimi guard shape).
# The directory is rewritten fresh on every spawn, which also drops the session
# record bin/fm-kiro-turnend-hook.sh keeps there, and bin/fm-teardown.sh retires
# it with `rm -rf`, so no separate registry cleanup is needed
# (bin/fm-control-lib.sh's auth path is empty for kiro-cli).
fm_kiro_build_task_home() {  # <kiro-home> <v2-agent-name-or-empty> <turn-end-path>
  local home=$1 v2_agent=$2 turnend=$3 auth_dir auth_file old_umask hook_command token
  [ -x "$FM_KIRO_TURNEND_HOOK" ] || {
    echo "error: kiro-cli turn-end hook missing or not executable at $FM_KIRO_TURNEND_HOOK" >&2
    return 1
  }
  hook_command=$(fm_kiro_task_hook_command "$home") || return 1
  rm -rf "$home" || return 1
  fm_kiro_write_settings "$home" || return 1
  if [ -n "$v2_agent" ]; then
    fm_kiro_write_v2_agent "$home" "$v2_agent" "$hook_command" || return 1
  fi
  auth_dir="$home/agents/fm-turn-end.d"
  mkdir -p "$auth_dir" || return 1
  old_umask=$(umask)
  umask 077
  auth_file=$(mktemp "$auth_dir/fm.XXXXXXXXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  printf '%s\n' "$turnend" > "$auth_file" || return 1
  token=${auth_file##*/}
  printf 'token=%s\n' "$token" > "$home/.fm-kiro-turnend" || return 1
  printf '%s\n' "$token"
}

fm_kiro_primary_home() {  # <state-dir>
  printf '%s/.kiro-primary-home' "${1%/}"
}
