#!/usr/bin/env bash
# claude-model-guard hook (UserPromptSubmit, and PreToolUse for Agent|Task): exit 2, which refuses the prompt or the
# subagent call, when this Claude Code session would run Fable. Sonnet is allowed. The fable alias resolves through
# env.ANTHROPIC_DEFAULT_FABLE_MODEL (install.sh maps it to Haiku), so it passes while that mapping is in effect. A full id
# such as claude-fable-5-1 cannot be remapped from user settings (availableModels and deniedModels only fall back to the
# default model, Opus), so it is refused here. Candidates: the --model of the claude process that runs this hook,
# ANTHROPIC_MODEL, the "model" key of the user and project settings, and the hook input.
set -uo pipefail
in=$(cat)
banned() {
  local v=${1,,}
  case $v in fable*) v=${ANTHROPIC_DEFAULT_FABLE_MODEL:-fable} ;; esac
  case ${v,,} in *fable*) return 0 ;; esac
  return 1
}
# The claude process: this hook's parent, past any shell Claude Code ran the command through.
p=$PPID
for _ in 1 2 3; do
  case $(readlink "/proc/$p/exe" 2>/dev/null) in */sh | */bash | */dash | */zsh) p=$(awk '{print $4}' "/proc/$p/stat") ;; *) break ;; esac
done
argv=()
[ -r "/proc/$p/cmdline" ] && mapfile -d '' -t argv < "/proc/$p/cmdline"
cands=("${ANTHROPIC_MODEL:-}")
for ((i = 0; i < ${#argv[@]}; i++)); do
  case ${argv[i]} in --model) cands+=("${argv[i + 1]:-}") ;; --model=*) cands+=("${argv[i]#--model=}") ;; esac
done
cwd=$(jq -r '.cwd // empty' <<<"$in" 2>/dev/null)
for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ${cwd:+"$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json"}; do
  [ -f "$f" ] && cands+=("$(jq -r '.model | strings' "$f" 2>/dev/null)")
done
mapfile -t -O "${#cands[@]}" cands < <(jq -r '(.model | strings), (.model | objects | .id | strings), (.tool_input.model | strings)' <<<"$in" 2>/dev/null)
for m in "${cands[@]}"; do
  [ -n "$m" ] && banned "$m" && { echo "claude-model-guard: model $m is Fable, which this host does not run; use sonnet, opus or haiku" >&2; exit 2; }
done
exit 0
