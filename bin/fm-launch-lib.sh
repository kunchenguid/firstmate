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
# The knowledge half of each adapter (busy-state source, exit command, dialogs,
# quirks) lives in the harness-adapters skill, not here.
#
# shell_quote lives here because both flag resolvers depend on it; sourcing this
# library is what makes it available to bin/fm-spawn.sh.

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# The verified launch command per adapter, as a template. A non-zero return has
# two distinct causes, and a caller reporting the refusal must tell them apart:
#   1. the harness has no verified adapter at all - the unverified-adapter guard
#      every caller relies on, whose remedy is a raw launch command;
#   2. the harness is verified but this kind is deliberately unsupported for it -
#      today only kimi with kind=primary, whose remedy is a different harness,
#      NOT the raw-launch escape hatch.
# Never add a permissive default arm to either case. bin/fm-spawn.sh:446 and :450
# name only cause 1 because fm-spawn never passes kind=primary; a consumer that
# does pass it owes the user the cause-2 wording.
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
# That same reasoning is why kimi has no primary arm: only bin/fm-spawn.sh can
# substitute __KIMIBIN__, and it only ever launches crewmates, so a primary kimi
# template could not be substituted by the caller that would ask for it.
#
# No primary template below is the crewmate command with its brief argument
# subtracted; each arm cites the specific in-repo evidence that fixes its flags,
# and tests/fm-launch-lib.test.sh pins each one against those same citations.
# The evidence is not uniform, and each arm says which kind it rests on: opencode
# and grok are pinned to an empirical briefless PRIMARY launch in a live e2e test,
# pi to the documented bare launch, and claude and codex to the secondmate
# precedent - this file's own `secondmate` kind is a firstmate PRIMARY (see the
# kind list above), and its shipped crewmate templates - the claude arm and the
# codex `kind = secondmate` arm in the second case block below - launch that
# interactive primary with exactly the autonomy flags those two arms carry.
#
# CONSUMER OBLIGATION (binding, not advisory). The rule, which governs whatever
# the templates below happen to say: EVERY primary template here starts a session
# that runs without permission prompts, and a consumer composing a primary launch
# MUST surface that to the captain at launch time. One short line at launch or in
# the menu row is enough. The captain is entitled to know the posture of the
# session their front door starts. There are no exempt adapters. The rule binds on
# the posture, not on the presence of a particular flag, so a consumer cannot
# satisfy the letter of this note while silently shipping a no-prompt session.
#
# All six reach that posture, four by an explicit bypass and the pi family
# structurally:
#   claude    --dangerously-skip-permissions
#   codex     --dangerously-bypass-approvals-and-sandbox
#   opencode  OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}', which
#             pre-allows every permission before the TUI starts
#   grok      --always-approve, which .agents/skills/harness-adapters/SKILL.md:304
#             records as auto-approving every tool execution, verified to run
#             fully unattended and equivalent to --permission-mode bypassPermissions
#   pi        (and pi-signed, which shares its arm) no flag, because none exists
#             to pass: SKILL.md:272 records that pi has no permission system at
#             all, so a pi session is autonomous by construction. Its template -
#             the bare selected binary plus the FM_PI_HARNESS identity marker,
#             which changes no permission posture - is complete, NOT missing an
#             autonomy flag its siblings carry - do not add one.
# Pi's first-run project trust dialog (SKILL.md:276-278) is folder trust, not a
# permission prompt, and is a separate concern that neither satisfies nor softens
# this obligation.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$kind" in
    primary)
      case "$harness" in
        # The ghost-text suppression prefix is firstmate-required on every claude
        # launch, primary included (see the crewmate arm below for why).
        # --dangerously-skip-permissions is settled knowledge, decided and recorded
        # rather than inherited by accident. The evidence is the secondmate
        # precedent: the claude arm in the crewmate case block below serves every
        # crewmate kind INCLUDING secondmate, and this `secondmate` kind is itself a
        # firstmate PRIMARY launched in a provisioned home, so the repo already
        # ships an interactive firstmate primary carrying this flag. The captain's
        # own attended session already runs as `claude --dangerously-skip-permissions`,
        # so keeping it preserves the status quo instead of creating new exposure,
        # and dropping it would break the supervision contract: a firstmate stalled
        # on a permission prompt cannot run bin/fm-wake-drain.sh to drain its wake
        # queue or bin/fm-watch-arm.sh to arm its own watcher. Note that README.md:90
        # documents the primary launch as bare `claude` and the only in-repo claude
        # launch carrying the flag directly is the headless print-mode session at
        # tests/fm-claude-stop-autoarm-live-e2e.test.sh:115; the secondmate
        # precedent, not those, is what fixes this arm. See the CONSUMER OBLIGATION
        # in the header: a consumer must tell the captain this session has no
        # permission prompts.
        claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__' ;;
        # --dangerously-bypass-approvals-and-sandbox rests on the same secondmate
        # precedent: the codex `kind = secondmate` arm in the crewmate case block
        # below is the SECONDMATE template, and it launches an
        # interactive firstmate primary with exactly this flag. The same status-quo
        # and supervision-contract reasoning as the claude arm applies. It is worth
        # recording what is NOT the evidence here:
        # tests/fm-codex-continuity-live-e2e.test.sh:40 runs `codex exec`, headless,
        # so it says nothing about the interactive primary TUI shape. The header's
        # CONSUMER OBLIGATION covers this arm too.
        codex) printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox' ;;
        # --prompt carries the crewmate's brief, so it has no place in a briefless
        # primary; --auto is the empirically verified briefless form (a primary
        # opencode TUI is launched that way in
        # tests/fm-opencode-primary-live-e2e.test.sh:256 and :310). The
        # OPENCODE_CONFIG_CONTENT JSON pre-allows every permission, so the header's
        # CONSUMER OBLIGATION covers this arm too.
        opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--auto' ;;
        # Bare `pi` is the documented primary launch (README.md:102); the project
        # trust prompt approved once per clone is what makes the tracked
        # .pi/extensions/*.ts auto-load (README.md:106), so a primary needs no
        # explicit -e flag. tests/fm-pi-primary-live-e2e.test.sh:266 adds
        # --approve --no-session --no-context-files --no-extensions with explicit
        # -e paths, but those are that test's isolation scaffolding - it runs
        # against a throwaway clone - not the verified primary form, so they are
        # deliberately not copied here. This template carries no autonomy flag
        # because pi has none to carry: SKILL.md:272 records that pi has no
        # permission system, so the session is autonomous by construction. The
        # header's CONSUMER OBLIGATION therefore covers this arm like every other -
        # a pi primary runs without permission prompts too, it just gets there
        # structurally rather than by a bypass flag. Nothing is missing here.
        # The FM_PI_HARNESS identity marker rides every Pi-family launch, primary
        # included (README.md:104 documents the signed primary as
        # `FM_PI_HARNESS=pi-signed pi-signed`): the selected $harness is both the
        # invoked binary and the marker, so a signed primary's environment cannot
        # relabel a plain Pi session.
        pi|pi-signed) printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__' ;;
        # --trust is supervision-safety knowledge, not one-time setup trivia:
        # without folder trust the primary turn-end guard FAILS OPEN
        # (.agents/skills/harness-adapters/SKILL.md:345), and because trust is
        # granted once per clone a fresh clone is exactly when its absence bites
        # (README.md:105, docs/turnend-guard.md:63). The empirical primary launch
        # is tests/fm-grok-continuity-live-e2e.test.sh:76,
        # `grok --trust --always-approve --reasoning-effort low`, where
        # --reasoning-effort is what __EFFORTFLAG__ resolves to; README.md:96
        # documents the same `grok --trust`. --always-approve auto-approves every
        # tool execution (.agents/skills/harness-adapters/SKILL.md:304), so the
        # header's CONSUMER OBLIGATION covers this arm: a consumer must tell the
        # captain this session has no permission prompts.
        grok) printf '%s' 'grok --trust --always-approve __MODELFLAG____EFFORTFLAG__' ;;
        # kimi refuses rather than emitting an unsubstitutable command: README.md:61
        # lists only Claude Code, Grok, Pi, pi-signed, Codex, and OpenCode as verified
        # primary harnesses (docs/configuration.md:177 defers that narrower set to README),
        # and only bin/fm-spawn.sh can resolve __KIMIBIN__ (see the header above).
        # A non-zero return is the same refusal an unverified adapter gets.
        kimi) return 1 ;;
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
    # pi-signed is a distinct executable identity that shares pi's verified flag
    # surface, never an alias: the selected $harness is both the invoked binary
    # and the FM_PI_HARNESS identity marker, so a signed primary's environment
    # cannot relabel a plain Pi worker (or vice versa). The marker is part of
    # the verified command, so it lives here, not in any caller.
    pi|pi-signed)
      if [ "$kind" = secondmate ]; then
        printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
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
    claude|codex|opencode|pi|pi-signed|grok|kimi)
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
    pi|pi-signed)
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
