#!/usr/bin/env bash
# fm-kiro-lib.sh - Kiro CLI home and project-scoped configuration owner.
#
# Kiro CLI V3 resolves custom agents and expanded hooks from the current
# project's .kiro/ tree.
# KIRO_HOME still owns Firstmate's settings, sessions, data, and logs, but KAS
# 0.66.4 (kiro-cli 2.22.1) can also discover the operator's global ~/.kiro
# configuration even when KIRO_HOME is set.
# Firstmate therefore uses both boundaries together:
#   - an isolated KIRO_HOME with chat.enableKnowledge=false;
#   - a task-specific project agent with the knowledge tool excluded, Powers
#     disabled, and capability `all` explicitly allowed for unattended work;
#   - a task-specific project Stop hook that reaches the tracked Kiro hook
#     adapter through FM_KIRO_HOOK.
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

fm_kiro_write_v2_agent() {  # <kiro-home> <agent-name>
  local home=$1 agent=$2
  fm_kiro_slug_valid "$agent" || return 1
  fm_kiro_prepare_home "$home" || return 1
  fm_kiro_publish_owned "$home/agents/$agent.json" <<EOF
{
  "name": "$agent",
  "description": "Firstmate-owned Kiro CLI V2 compatibility agent.",
  "tools": ["*"],
  "allowedTools": ["*"],
  "hooks": {
    "userPromptSubmit": [
      { "command": "\"\${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\"" }
    ],
    "preToolUse": [
      { "command": "\"\${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\"" }
    ],
    "postToolUse": [
      { "command": "\"\${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\"" }
    ],
    "stop": [
      { "command": "\"\${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\"" }
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
  local workspace=$1 id=$2 home=$3 agent agent_path hook_path agent_home hook_home
  [ -d "$workspace" ] && [ ! -L "$workspace" ] || return 1
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  fm_kiro_slug_valid "$id" || return 1
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
  fm_kiro_publish_owned "$hook_home" <<'EOF' || return 1
{
  "version": "v1",
  "hooks": [
    {
      "name": "firstmate-prompt-submit",
      "trigger": "UserPromptSubmit",
      "action": {
        "type": "command",
        "command": "\"${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\""
      }
    },
    {
      "name": "firstmate-pre-tool",
      "trigger": "PreToolUse",
      "action": {
        "type": "command",
        "command": "\"${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\""
      }
    },
    {
      "name": "firstmate-post-tool",
      "trigger": "PostToolUse",
      "action": {
        "type": "command",
        "command": "\"${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\""
      }
    },
    {
      "name": "firstmate-stop",
      "trigger": "Stop",
      "action": {
        "type": "command",
        "command": "\"${FM_KIRO_HOOK:-bin/fm-kiro-turnend-hook.sh}\""
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

fm_kiro_primary_home() {  # <state-dir>
  printf '%s/.kiro-primary-home' "${1%/}"
}
