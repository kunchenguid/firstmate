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
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse) return 0 ;;
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
    cursor*) printf 'cursor' ;;
    muse*) printf 'muse' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse is a crewmate/scout
# adapter only: it has no primary supervision protocol, and bin/fm-spawn.sh
# refuses a --secondmate launch on it.
#
# cursor is refused for EVERY ordinary unattended kind - ship, scout, AND
# secondmate. It launches under --auto-review --sandbox enabled, which keeps a
# real filesystem sandbox but accepts that cursor's server classifier prompts
# for any call it does not deem safe. An unattended pane has no approver, and
# the cursor-transcript busy fold keeps a parked pane reading as working, so the
# stall never surfaces as a hold. A cursor secondmate is the worst case, because
# a whole firstmate instance stalls invisibly.
#
# The optional third argument is the caller's EXEMPTION grant, which is the only
# opt-in past the cursor refusal:
#   attended         - a person is in the pane and can answer the prompt.
#   envelope:<name>  - the named outer isolation envelope governs the worker.
# Any other value, including an empty one, is no exemption, so an ordinary
# unattended spawn stays refused. The grant is PER TASK, never ambient: it
# arrives as bin/fm-spawn.sh's --cursor-exemption flag and is recorded in that
# task's own meta, so it can neither leak from one spawn to the next in a shell
# nor be inherited by an unrelated spawn.
#
# The harness is canonicalized first, so a raw launch command whose basename is
# `cursor-agent` is held to the same rule as the `cursor` adapter name rather
# than slipping past the table through the unverified-adapter escape hatch.
#
# This function is the ONE owner of which kinds an adapter may run: both muse's
# secondmate rule and cursor's unattended rule live here only, and
# bin/fm-spawn.sh asks it for every verified harness rather than repeating any
# of it, so the launch owner and the control plane cannot drift. The control
# plane asks it BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind> [exemption]
  local harness=${1-} kind=${2-} exemption=${3-} canonical
  canonical=$(fm_control_harness_family "$harness") || return 1
  fm_control_harness_supported "$canonical" || return 1
  case "$canonical" in
    muse|gemini) [ "$kind" != secondmate ] || return 1 ;;
    cursor) fm_control_cursor_exemption_valid "$exemption" || return 1 ;;
  esac
  return 0
}

# The ONE owner of what a cursor exemption grant may say. `attended` is a fixed
# token; an envelope grant must NAME its envelope in a bounded single-line
# charset, exactly the way every other recorded posture field is whitelisted.
# Two properties depend on that bound. An unnamed or free-form grant could not
# be audited back to a real envelope later, and the grant is written verbatim
# into the task record as `cursor_exemption=<grant>`, where a value carrying a
# newline would append a second `key=` line that fm_meta_get's last-match
# resolution would then prefer over the real one - a grant that could silently
# rewrite the task's recorded merge authority. Both refusal sites ask here.
fm_control_cursor_exemption_valid() {  # <grant>
  local grant=${1-} name
  # The bracket ranges below are COLLATION-ordered, so without this the bound
  # this function advertises would differ per machine: under en_US.UTF-8
  # `envelope:unicode-with-accents` matches [A-Za-z0-9] and is accepted, while
  # under C it is refused. fm_task_id_path_safe in bin/fm-pr-lib.sh pins the
  # locale for exactly this reason, and the one owner of the grant charset must
  # answer the same question everywhere or the recorded grant is unauditable.
  local LC_ALL=C
  case "$grant" in
    attended) return 0 ;;
    envelope:*)
      name=${grant#envelope:}
      case "$name" in
        ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      return 0
      ;;
  esac
  return 1
}

# The grant that is still in force for an UNATTENDED relaunch of a task whose
# record holds <recorded-grant> onto <target-harness>. Prints that grant, or
# nothing when none survives. Two independent conditions must both hold.
#
# envelope:<name> describes a mechanically proven outer isolation envelope that
# still governs the replacement agent, so it carries over and automatic recovery
# keeps working. `attended` asserts that a PERSON IS IN THE PANE RIGHT NOW,
# which a later relaunch cannot inherit: the captain who attested may have
# walked away hours before firstmate's own stuck-worker recovery relaunches with
# nobody there.
#
# The grant also describes an exemption from CURSOR's unattended bar and nothing
# else, so it survives only onto cursor. A relaunch that resolves to another
# adapter drops it rather than carrying it into that task's record, where a
# later relaunch back onto cursor would read it as authority nobody granted for
# cursor. Dropping is right here and refusing is not: the harness switch itself
# is legitimate, and refusing it after the control plane had already stopped the
# agent is the stranding this helper exists to prevent.
#
# This is the ONE owner of that inheritance rule. bin/fm-spawn.sh's --relaunch
# path asks it for the grant it will actually launch under, and the control
# plane's PRE-STOP capability check in bin/fm-control.sh asks it for the grant
# it must evaluate the relaunch against. Restating the rule at either site
# would let the two answers disagree, and a disagreement here stops a running
# agent for a launch the owner then refuses.
fm_control_cursor_exemption_inherited() {  # <recorded-grant> <target-harness>
  local grant=${1-} target=${2-}
  fm_control_cursor_exemption_valid "$grant" || return 0
  [ "$grant" != attended ] || return 0
  fm_control_cursor_exemption_applies "$target" || return 0
  printf '%s' "$grant"
}

# Whether a cursor exemption is meaningful for a launch on <harness>. A grant
# accepted and RECORDED on another adapter would leave a stale cursor grant in
# that task's meta, which a later relaunch onto cursor would read back as
# authority nobody granted for cursor. Every spawn route - the local launch
# owner and the remote secondmate route alike - asks this one predicate, so a
# route cannot be the one that forgets the rule.
fm_control_cursor_exemption_applies() {  # <harness>
  local canonical
  canonical=$(fm_control_harness_family "${1-}" 2>/dev/null) || return 1
  [ "$canonical" = cursor ]
}

fm_control_cursor_exemption_harness_refusal() {  # <harness>
  printf -- "--cursor-exemption applies only to a cursor launch, but this spawn resolved harness=%s; drop the flag rather than recording a cursor grant that would outlive it" "${1-}"
}

# The operator-facing reason a harness cannot run a kind. Both refusal sites -
# the launch owner in bin/fm-spawn.sh and the pre-stop relaunch check in
# bin/fm-control.sh - print this, so the diagnostic cannot drift from the table
# above the way a hand-written message at each site would.
fm_control_harness_kind_refusal() {  # <harness> <kind>
  local harness=${1-} kind=${2-} canonical
  canonical=$(fm_control_harness_family "$harness") || {
    printf "'%s' is not a verified adapter, so it is not verified to run a %s task" "$harness" "$kind"
    return 0
  }
  case "$canonical" in
    muse)
      printf 'muse is a verified crewmate/scout adapter only and cannot run a secondmate; it has no primary supervision protocol. Select a harness verified for secondmates.'
      ;;
    cursor)
      printf "cursor is a verified adapter but is refused for an unattended %s launch: its --auto-review classifier prompts for calls it does not deem safe, the pane has no approver, and the parked pane keeps reading as busy. The bar applies however cursor was selected, INCLUDING when firstmate inherited it by detecting its own runtime, because silently substituting another tool would change which adapter runs the captain's work without saying so. If this home is running inside cursor and resolved it that way, set config/crew-harness to a verified adapter such as codex or claude, or add a crew-dispatch profile eligible for this kind; firstmate will not choose one for you. If a person is in the pane or a proven outer isolation envelope governs this worker, pass it on the spawn itself with --cursor-exemption attended or --cursor-exemption envelope:<name>." "$kind"
      ;;
    *)
      printf "'%s' is not verified to run a %s task" "$canonical" "$kind"
      ;;
  esac
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|kimi|cursor|muse) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|grok|kimi|cursor|muse) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
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
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse) printf '/exit' ;;
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
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
  esac
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
