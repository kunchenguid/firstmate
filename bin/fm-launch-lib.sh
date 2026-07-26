#!/usr/bin/env bash
# fm-launch-lib.sh - the single owner of firstmate's verified launch commands.
#
# Every firstmate-launched agent session composes its command from exactly these
# three functions. There is no second copy anywhere, and a caller must never
# hand-write a launch string: the drift that causes is not hypothetical. A
# downstream registry once hand-copied claude's command as
# `claude --dangerously-skip-permissions`, dropping the ghost-text suppression
# variable documented in launch_template() below - the exact omission that makes
# firstmate read predicted-prompt text as real typed input when it captures a
# pane. One owner, or that happens again.
#
# Sourced by bin/fm-spawn.sh (crewmate, scout, and secondmate sessions).
#
#   launch_template <harness> [<kind>]      the verified launch command, with
#                                           placeholders the caller substitutes
#   model_flag_for_harness <harness> <model>    resolved --model flag, or empty
#   effort_flag_for_harness <harness> <effort>  resolved effort flag, or empty
#
# The knowledge half of each adapter (busy signature, exit command, dialogs,
# quirks) lives in the harness-adapters skill, not here.
#
# shell_quote lives here because both flag resolvers depend on it; sourcing this
# library is what makes it available to bin/fm-spawn.sh.

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# The verified launch command per adapter, as a template. Returns 1 for a
# harness with no verified adapter - that non-zero return is the unverified-
# adapter guard every caller relies on, so never add a permissive default arm.
#
# kind selects the session shape:
#   ship|scout   a crewmate working one task in an isolated worktree
#   secondmate   a firstmate PRIMARY launched in a provisioned secondmate home
#   primary      a firstmate PRIMARY launched in this home by the fleet launcher
#
# ship, scout, and secondmate all receive a launch brief, so their templates end
# in the encoded brief argument. A primary has no task, no worktree, no brief,
# and no status file, so it launches bare and is greeted by the session-start
# adapters already installed in the home (for pi and opencode those are the
# project-local extensions the harness auto-discovers once trusted, which is why
# a primary needs no explicit extension flag). A primary template therefore
# carries only its flag placeholders plus whatever briefless-launch flag that
# adapter was verified to need, and an unset flag leaves one trailing space; that
# is cosmetic in a shell command, and consumers may trim it.
#
# Placeholders every caller substitutes before launch:
#   __MODELFLAG__  model_flag_for_harness output, or empty (see below)
#   __EFFORTFLAG__ effort_flag_for_harness output, or empty (see below)
#   __KIMIBIN__    shell-quoted absolute path to the resolved kimi binary
# Placeholders only a task-scoped (ship|scout|secondmate) launch substitutes:
#   __BRIEF__     absolute path to data/<task-id>/brief.md
#   __TURNEND__   absolute path to state/<task-id>.turn-ended (for harnesses whose
#                 turn-end signal rides the launch command, e.g. codex -c notify=[...])
#   __PIEXT__     absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                 written by fm-spawn.sh; outside the worktree to avoid pi's trust gate)
#   __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#   __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#   __OPINPUT__   absolute path to the canonical operational-input encoder
#
# __KIMIBIN__ is resolved by bin/fm-spawn.sh alone, deliberately: the fleet
# launcher reaches Kimi through the pi harness rather than a native kimi binary,
# so there is no second caller to drift from.
# Revisit that only if a native kimi launch ever becomes a launcher entry.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$kind" in
    primary)
      case "$harness" in
        claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__' ;;
        codex) printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox' ;;
        # --prompt carries the crewmate's brief, so it has no place in a briefless
        # primary; --auto is the empirically verified briefless form (a primary
        # opencode TUI is launched that way in
        # tests/fm-opencode-primary-live-e2e.test.sh:256 and :310).
        opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--auto' ;;
        pi) printf '%s' 'pi __MODELFLAG____EFFORTFLAG__' ;;
        grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__' ;;
        # Kimi Code rejects a positional prompt, so its crewmate template
        # already launches bare; the primary shape is identical.
        kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
        *) return 1 ;;
      esac
      return 0
      ;;
  esac
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
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by fm-spawn.sh (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # only an absolute brief pointer after fm-spawn.sh's TUI readiness gate.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task worktree token, so no launch placeholder belongs here.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    *) return 1 ;;
  esac
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok|kimi)
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
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command.
  esac
}
