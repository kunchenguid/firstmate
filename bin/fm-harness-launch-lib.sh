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

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
fm_launch_template() {
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
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by
    # fm_launch_install_turn_end_hook (global hook + per-task pointer), so the
    # template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

fm_launch_model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(fm_launch_shell_quote "$model")"
      ;;
  esac
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
      # The installed codex config schema uses model_reasoning_effort, and the
      # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
      # than passing an unsupported value.
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(fm_launch_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(fm_launch_shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
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
  local grok_hooks_dir grok_auth_dir old_umask auth_file sq_grok_auth_dir hook_command prior_token
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
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$state/$id.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn/fm-rehome-quota-wall.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$turnend"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      grok_hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks"
      grok_auth_dir="$grok_hooks_dir/fm-turn-end.d"
      mkdir -p "$grok_auth_dir"
      # A relaunch (rehome) re-mints the token, and teardown only removes the
      # currently recorded one, so retire the previous auth file here.
      prior_token=$(cat "$state/$id.grok-turnend-token" 2>/dev/null || true)
      case "$prior_token" in
        ''|*[!A-Za-z0-9._-]*) ;;
        *) rm -f "$grok_auth_dir/$prior_token" ;;
      esac
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
  esac
  : "$project_abs"
}
