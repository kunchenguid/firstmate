#!/usr/bin/env bash
# bin/fm-launch-lib.sh - shared launch-command construction, sourced by
# bin/fm-spawn.sh (fresh worktree launches) and bin/fm-resume-worktree.sh
# (re-launch into an existing worktree, no `treehouse get`). Keeping this in
# one place means the two never drift on what a harness's launch command
# looks like, what --model/--effort flags it accepts, or how firstmate's own
# proxy env is threaded through. The knowledge half of each adapter (busy
# signature, exit command, dialogs, quirks) lives in the harness-adapters
# skill, not here.
#
# Sourced only, never executed directly: `. "$SCRIPT_DIR/fm-launch-lib.sh"`.

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Firstmate may reach the Anthropic API/OAuth (and git remotes) through a local
# routing proxy on restricted networks. A freshly spawned crewmate pane inherits
# no environment by default, so it would take a direct route and get rejected or
# hang. Propagating the same proxy vars firstmate itself has set makes the
# crewmate (and treehouse's own `git fetch` during worktree provisioning) take
# firstmate's working route. Prints an `export VAR=val ...` prefix, or nothing
# when no proxy vars are set.
proxy_env_prefix() {
  local pv val prefix=
  for pv in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
    eval "val=\${$pv-}"
    [ -n "$val" ] || continue
    prefix="$prefix $pv=$(shell_quote "$val")"
  done
  printf '%s' "$prefix"
}

proxy_env_source_command() {
  local task_tmp=$1 file tmp pv val wrote old_umask
  file="$task_tmp/proxy-env.sh"
  tmp="$file.$$"
  wrote=0
  mkdir -p "$task_tmp" || return 1
  chmod 700 "$task_tmp" || return 1
  old_umask=$(umask)
  umask 077
  : > "$tmp" || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  for pv in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
    eval "val=\${$pv-}"
    [ -n "$val" ] || continue
    printf 'export %s=%s\n' "$pv" "$(shell_quote "$val")" >> "$tmp" || { rm -f "$tmp"; return 1; }
    wrote=1
  done
  if [ "$wrote" -eq 0 ]; then
    rm -f "$tmp" "$file"
    return 0
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  printf '. %s' "$(shell_quote "$file")"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob, and --reasoning-effort rejects max, so pass
      # only its accepted shared vocabulary subset.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # pi accepts --thinking low|medium|high|xhigh. It warns and ignores max, so
      # omit max rather than passing a flag the installed CLI will reject as invalid.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so this is not passed.
  esac
}

# The verified launch command per adapter. Placeholders (__MODELFLAG__,
# __EFFORTFLAG__, __BRIEF__, __TURNEND__, __PIEXT__) are replaced by the
# caller before launch.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed separately (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}
