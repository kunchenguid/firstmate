#!/usr/bin/env bash
# fm-launch-lib.sh - the single owner of verified harness launch-command
# construction and per-task turn-end hook installation.
#
# Extracted verbatim from bin/fm-spawn.sh so the ordinary spawn path and the
# guarded active-worker provider-failover relaunch path (bin/fm-failover.sh)
# share ONE launch contract instead of two copies that can drift. fm-spawn.sh
# remains the owner of spawn orchestration (backend/worktree creation, meta,
# batch dispatch); this library owns only:
#   - fm_launch_template          verified launch command per adapter and kind
#   - fm_launch_shell_quote       single-quote shell escaping for launch text
#   - fm_launch_json_escape       minimal JSON string escaping for hook files
#   - fm_launch_model_flag        per-harness --model flag rendering
#   - fm_launch_effort_flag       per-harness effort flag rendering
#   - fm_launch_exclude_path      git info/exclude entry for worktree hook files
#   - fm_launch_install_turnend_hook  per-harness crewmate turn-end hook install
#   - fm_launch_render            placeholder substitution into a launch template
# The knowledge half of each adapter (busy signature, exit command, dialogs,
# quirks) stays in the harness-adapters skill; fm-spawn.sh's header stays the
# owner of the placeholder vocabulary (__BRIEF__, __TURNEND__, __PIEXT__,
# __PITURNEND__, __PIWATCH__, __MODELFLAG__, __EFFORTFLAG__).

# The verified launch command per adapter. See fm-spawn.sh's header for the
# placeholder vocabulary these templates carry.
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
    # fm_launch_install_turnend_hook (global hook + per-task pointer), so the
    # template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

fm_launch_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_launch_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fm_launch_model_flag() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(fm_launch_shell_quote "$model")"
      ;;
  esac
}

fm_launch_effort_flag() {
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

# fm_launch_fable_effort_cap: print the effective effort for a launch, applying
# the captain's standing Fable rule: every Claude Fable launch (ordinary spawn
# or provider-failover relaunch) runs at NORMAL speed and at most effort high -
# xhigh and max are clamped to high, and no speed/fast-mode flag is ever
# emitted (the claude template carries none by design). Other harnesses and
# non-Fable claude models pass through unchanged. fm_launch_render applies this
# cap at the single render choke point; callers that record effort in task
# metadata apply it first so records match the real launch.
fm_launch_fable_effort_cap() {  # <harness> <model> <effort>
  local harness=$1 model=$2 effort=$3
  if [ "$harness" = claude ]; then
    case "$model" in
      *fable*)
        case "$effort" in
          xhigh|max) printf 'high'; return 0 ;;
        esac
        ;;
    esac
  fi
  printf '%s' "$effort"
}

# fm_launch_exclude_path: keep a worktree-resident hook file out of git's view so
# it never blocks teardown's dirty check or leaks into a commit.
fm_launch_exclude_path() {  # <worktree> <relative-path>
  local wt=$1 rel=$2 EXCL
  EXCL=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}

# fm_launch_install_turnend_hook: install the per-harness crewmate turn-end
# hook - a file that touches <turnend> when the agent finishes a turn.
# Worktree-resident hooks are kept out of git's view (fm_launch_exclude_path)
# so they never block teardown's dirty check or leak into a commit. Callers
# pass the ship/scout task's worktree; the secondmate spawn path never calls
# this (a secondmate's turn-end integration is its own tracked home material).
fm_launch_install_turnend_hook() {  # <harness> <worktree> <state-dir> <id> <turnend>
  local harness=$1 wt=$2 state=$3 id=$4 turnend=$5
  local GROK_HOOKS_DIR GROK_AUTH_DIR old_umask auth_file sq_grok_auth_dir hook_command
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
// Firstmate turn-end signal; written by fm-spawn.
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
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$turnend" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$state/$id.grok-turnend-token"
      sq_grok_auth_dir=$(fm_launch_shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
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
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(fm_launch_json_escape "bash $(fm_launch_shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$wt/.fm-grok-turnend"
      fm_launch_exclude_path "$wt" '.fm-grok-turnend'
      ;;
  esac
}

# Launch-time pane primitives, dispatched per backend. These are the exact
# per-backend calls fm-spawn.sh's launch sequence has always made (zellij and
# cmux take the expected task label as an extra argument); the failover
# relaunch path reuses them so the two launch sequences cannot drift. Callers
# must have sourced bin/fm-backend.sh and the relevant backend adapter
# (fm_backend_source) first.
fm_launch_send_text_line() {  # <backend> <target> <text> <label>
  case "$1" in
    tmux) fm_backend_tmux_send_text_line "$2" "$3" ;;
    herdr) fm_backend_herdr_send_text_line "$2" "$3" ;;
    zellij) fm_backend_zellij_send_text_line "$2" "$3" "$4" ;;
    orca) fm_backend_orca_send_text_line "$2" "$3" ;;
    cmux) fm_backend_cmux_send_text_line "$2" "$3" "$4" ;;
  esac
}

fm_launch_send_literal() {  # <backend> <target> <text> <label>
  case "$1" in
    tmux) fm_backend_tmux_send_literal "$2" "$3" ;;
    herdr) fm_backend_herdr_send_literal "$2" "$3" ;;
    zellij) fm_backend_zellij_send_literal "$2" "$3" "$4" ;;
    orca) fm_backend_orca_send_literal "$2" "$3" ;;
    cmux) fm_backend_cmux_send_literal "$2" "$3" "$4" ;;
  esac
}

fm_launch_send_key() {  # <backend> <target> <key> <label>
  case "$1" in
    tmux) fm_backend_tmux_send_key "$2" "$3" ;;
    herdr) fm_backend_herdr_send_key "$2" "$3" ;;
    zellij) fm_backend_zellij_send_key "$2" "$3" "$4" ;;
    orca) fm_backend_orca_send_key "$2" "$3" ;;
    cmux) fm_backend_cmux_send_key "$2" "$3" "$4" ;;
  esac
}

fm_launch_current_path() {  # <backend> <target> <label>
  case "$1" in
    tmux) fm_backend_tmux_current_path "$2" ;;
    herdr) fm_backend_herdr_current_path "$2" ;;
    zellij) fm_backend_zellij_current_path "$2" "$3" ;;
    cmux) fm_backend_cmux_current_path "$2" "$3" ;;
  esac
}

# fm_launch_render: substitute the model/effort flags and every path
# placeholder into a launch template and print the rendered command. Paths are
# shell-quoted here so callers pass them raw.
fm_launch_render() {  # <launch> <harness> <model> <effort> <brief> <turnend> <piext> <piturnend> <piwatch>
  local launch=$1 harness=$2 model=$3 effort=$4 brief=$5 turnend=$6 piext=$7 piturnend=$8 piwatch=$9
  local sq_brief sq_turnend sq_piext sq_piturnend sq_piwatch modelflag effortflag
  sq_brief=$(fm_launch_shell_quote "$brief")
  sq_turnend=$(fm_launch_shell_quote "$turnend")
  sq_piext=$(fm_launch_shell_quote "$piext")
  sq_piturnend=$(fm_launch_shell_quote "$piturnend")
  sq_piwatch=$(fm_launch_shell_quote "$piwatch")
  modelflag=$(fm_launch_model_flag "$harness" "$model")
  effort=$(fm_launch_fable_effort_cap "$harness" "$model" "$effort")
  effortflag=$(fm_launch_effort_flag "$harness" "$effort")
  launch=${launch//__MODELFLAG__/$modelflag}
  launch=${launch//__EFFORTFLAG__/$effortflag}
  launch=${launch//__BRIEF__/$sq_brief}
  launch=${launch//__TURNEND__/$sq_turnend}
  launch=${launch//__PIEXT__/$sq_piext}
  launch=${launch//__PITURNEND__/$sq_piturnend}
  launch=${launch//__PIWATCH__/$sq_piwatch}
  printf '%s' "$launch"
}
