#!/usr/bin/env bash
# Shared harness launch templates, profile flags, shell quoting, and turn-end
# hook installation.
#
# fm-spawn.sh and fm-rehome-quota-wall.sh both need to launch a verified
# harness in a firstmate-owned task endpoint.
# This file is the single owner of the launch-command fragments and the
# worktree/state hook files required for turn-end signaling.

fm_launch_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_launch_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fm_launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016
  case "$harness" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false __CLAUDE_OAUTH_EXEC__claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'CODEX_HOME=__CODEX_HOME__ codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' '__PIBRIEFENV__ pi __PROVIDERFLAG____MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' '__PIBRIEFENV__ pi __PROVIDERFLAG____MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    omp)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'bun "$HOME/.bun/bin/omp" --auto-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'bun "$HOME/.bun/bin/omp" --auto-approve __MODELFLAG____EFFORTFLAG__--hook __OMPEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

fm_launch_model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok|omp)
      printf -- '--model %s ' "$(fm_launch_shell_quote "$model")"
      ;;
  esac
}

fm_launch_provider_flag_for_harness() {
  local harness=$1 model=$2 provider=
  [ "$harness" = pi ] || return 0
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$model" in
    */*) return 0 ;;
  esac
  provider=$(fm_launch_pi_provider_for_model "$model" || true)
  [ -n "$provider" ] || return 0
  printf -- '--provider %s ' "$(fm_launch_shell_quote "$provider")"
}

fm_launch_pi_provider_for_model() {
  local model=$1 models_json=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json
  [ -f "$models_json" ] || return 1
  node -e '
const fs = require("node:fs")
const [file, wanted] = process.argv.slice(1)
try {
  const data = JSON.parse(fs.readFileSync(file, "utf8"))
  for (const [provider, cfg] of Object.entries(data.providers ?? {})) {
    for (const model of cfg.models ?? []) {
      if (model && model.id === wanted) {
        console.log(provider)
        process.exit(0)
      }
    }
  }
} catch {}
process.exit(1)
' "$models_json" "$model"
}

fm_launch_effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(fm_launch_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    omp)
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
  esac
}

fm_launch_exclude_path() {
  local wt=$1 rel=$2 excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$excl" ] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF "$rel" "$excl" 2>/dev/null || echo "$rel" >> "$excl"
}

fm_launch_install_turn_end_hook() {
  local harness=$1 kind=$2 wt=$3 state=$4 id=$5 turnend=$6 project_abs=$7
  local grok_hooks_dir grok_auth_dir old_umask auth_file sq_grok_auth_dir hook_command
  [ "$kind" != secondmate ] || return 0
  case "$harness" in
    claude*)
      mkdir -p "$wt/.claude"
      cat > "$wt/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$turnend'"}]}]}}
EOF
      fm_launch_exclude_path "$wt" '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$wt/.opencode/plugins"
      cat > "$wt/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $turnend\`
  },
})
EOF
      fm_launch_exclude_path "$wt" '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      cat > "$state/$id.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn/fm-rehome-quota-wall.
// Use "turn_end" so the watcher sees every completed agent turn.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$turnend"]));
}
EOF
      ;;
    codex*)
      ;;
    grok*)
      grok_hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks"
      grok_auth_dir="$grok_hooks_dir/fm-turn-end.d"
      mkdir -p "$grok_auth_dir"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$grok_auth_dir/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$turnend" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$state/$id.grok-turnend-token"
      sq_grok_auth_dir=$(fm_launch_shell_quote "$grok_auth_dir")
      cat > "$grok_hooks_dir/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$grok_hooks_dir/fm-turn-end.sh"
      hook_command=$(fm_launch_json_escape "bash $(fm_launch_shell_quote "$grok_hooks_dir/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$grok_hooks_dir/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$wt/.fm-grok-turnend"
      fm_launch_exclude_path "$wt" '.fm-grok-turnend'
      ;;
    omp*)
      cat > "$state/$id.omp-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn/fm-rehome-quota-wall.
import { execFile } from "node:child_process";
export default function (omp: any) {
  omp.on("turn_end", () => execFile("touch", ["$turnend"]));
}
EOF
      ;;
  esac
  : "$project_abs"
}
