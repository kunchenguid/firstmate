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
# refuses a --secondmate launch on it. The control plane
# asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
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
# never a harness's own managed config. claude is deliberately absent: its
# wiring lives inside a file a project may commit and merge real content
# into, so a blind rm -f is unsafe there and fm_control_claude_settings_clear
# (below) is the one owner of clearing it instead.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
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

# claude's per-task busy hooks live inside <worktree>/.claude/settings.local.json,
# a path a project may itself commit (permissions, env, enabledPlugins, and even
# its own OTHER Claude Code hooks, e.g. a PreToolUse linter). The functions below
# are the one owner of installing and retiring firstmate's own content there
# without ever destroying a project's: fm-spawn.sh probes
# fm_control_claude_settings_mergeable before arming the busy contract and calls
# fm_control_claude_settings_install to arm or re-arm, clear_relaunch_harness_wiring
# calls fm_control_claude_settings_clear to retire, and bin/fm-teardown.sh calls
# fm_control_claude_settings_only_owned_differ to decide whether a tracked file's
# only working-tree difference from HEAD is firstmate's own hook entries.
#
# Ownership is STRUCTURAL, never inferred from file content: at install time
# firstmate records the exact hook COMMAND STRINGS it minted for this task in
# a private per-task state file (state/<id>.claude-settings-owned, a
# {"version":1,"preexisted":<bool>,"commands":{"<event>":["<command>",...]}}
# document outside the worktree), and a later strip, clear, or restore
# decision treats a hook as firstmate's own only when its command is
# string-equal to one recorded there for that event. No substring, pattern,
# or heuristic ever classifies anything: a project hook whose command text
# merely mentions fm-busy-event.sh is not string-equal to any recorded
# command, while a minted command embeds the resolved state path, the task
# id, and the per-incarnation --gen token, so a project cannot author a
# matching hook without copying one byte-for-byte. The command string - not
# the surrounding hook-group entry object - is the ownership identity because
# claude itself rewrites this file (a mid-task permission grant re-serializes
# it from claude's own parsed model and may add or default sibling fields on
# an entry); a command is opaque content no other writer has a reason to
# alter, so ownership survives such a rewrite where whole-entry deep equality
# would be silently and permanently lost, stranding an unremovable entry and
# a false teardown refusal. A hook-group entry is dropped only once every
# command in it is firstmate's own; a mixed entry keeps the project's
# commands and loses only firstmate's.
#
# The record is MONOTONE within a task: install writes the union of the old
# record's commands and the fresh incarnation's BEFORE touching the settings
# file, and install never narrows it, so an interruption between the two
# writes leaves a correct-or-over-broad record, never one that orphans a
# previous incarnation's still-installed entries; an over-broad record can
# only name commands minted for this task, which strip simply does not find
# in the file. Re-installing strips every recorded command before appending
# the fresh incarnation's, so a respawn or relaunch fully replaces
# firstmate's own entries rather than accumulating them; with no record
# nothing is provably firstmate's, so nothing is stripped and nothing is
# restored (a file armed by a pre-record firstmate keeps its stale entries,
# which the busy-generation gate refuses harmlessly, and bin/fm-teardown.sh
# names the file and the missing record in its refusal so the operator is not
# left guessing). preexisted records whether the settings file already
# existed before firstmate's first install for the task, carried forward
# while the record lives (and treated as true when a record omits it); clear
# retires the record, so a clear-then-install cycle re-derives it from the
# file's presence, which can only err toward KEEPING a file, never toward
# deleting a project's. Clearing may remove the file only when firstmate
# created it AND nothing but firstmate's own entries ever landed in it.
#
# A settings file that cannot be merged into is REFUSED, never overwritten:
# install fails loudly on unparseable JSON, a non-object top level, or a
# non-object "hooks" value, leaving the original bytes untouched, because
# destroying a project's committed configuration is the exact bug this
# contract exists to prevent (issue #3111). A zero-byte file is the one
# accepted degenerate case: it has no content to protect and merges as the
# empty object, and the diff predicate compares an empty document as that
# same empty object so a committed zero-byte file still restores cleanly.
# Two accepted limitations, stated rather than hidden: install rewrites the
# whole document as compact jq output, so formatting is not preserved and
# number-literal fidelity follows the installed jq (jq older than 1.7
# rewrites large integers and float literals, and duplicate keys always
# collapse to the last); and a settings file that is a symlink is replaced by
# a regular file by the atomic rename.
# shellcheck disable=SC2016  # single quotes are deliberate: these are jq programs whose $rec/$fresh/$cmds/$k vars are jq variables, not shell ones
_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS='
  def fm_own_hook($cmds):
    (.command? // null) as $c
    | (($c | type) == "string") and any($cmds[]?; . == $c);
  def fm_strip_recorded($rec):
    if (has("hooks")) and ((.hooks | type) == "object") then
      .hooks |= with_entries(
        .key as $k
        | if ($rec | has($k)) and ((.value | type) == "array") then
            .value |= map(
              if (type == "object") and (((.hooks? // null) | type) == "array") then
                (.hooks | map(select(fm_own_hook($rec[$k]) | not))) as $kept
                | if (($kept | length) == 0) and ((.hooks | length) > 0) then empty
                  elif ($kept | length) == (.hooks | length) then .
                  else .hooks = $kept
                  end
              else . end)
          else . end)
    else . end;
  def fm_fragment_commands:
    map_values([ .[] | .hooks[]? | .command? | strings ]);
  def fm_norm_hooks:
    if (has("hooks")) and ((.hooks | type) == "object") then
      (.hooks | with_entries(select((((.value | type) == "array") and ((.value | length) == 0)) | not))) as $h
      | if ($h | length) == 0 then del(.hooks) else .hooks = $h end
    else . end;
'
# shellcheck disable=SC2016
_FM_CONTROL_CLAUDE_SETTINGS_INSTALL_JQ="$_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS"'
  fm_strip_recorded($rec)
  | .hooks = (reduce ($fresh | keys[]) as $k ((.hooks // {}); .[$k] = ((.[$k] // []) + $fresh[$k])))
'
# shellcheck disable=SC2016
_FM_CONTROL_CLAUDE_SETTINGS_STRIP_ONLY_JQ="$_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS"'
  fm_strip_recorded($rec)
'
_FM_CONTROL_CLAUDE_SETTINGS_NORM_JQ="$_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS"'
  fm_norm_hooks
'
# shellcheck disable=SC2016
_FM_CONTROL_CLAUDE_SETTINGS_STRIP_NORM_JQ="$_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS"'
  fm_strip_recorded($rec) | fm_norm_hooks
'
# The monotone record body: the old record's per-event command lists unioned
# with the commands inside the fresh hooks fragment, never narrowed.
# shellcheck disable=SC2016
_FM_CONTROL_CLAUDE_SETTINGS_RECORD_JQ="$_FM_CONTROL_CLAUDE_SETTINGS_JQ_DEFS"'
  ($fresh | fm_fragment_commands) as $fc
  | {version: 1, preexisted: $preexisted,
     commands: (reduce ($fc | keys[]) as $k ($old; .[$k] = (((.[$k] // []) + $fc[$k]) | unique)))}
'

# Read the per-event commands object out of an ownership record file, printing
# {} for an absent record (nothing recorded means nothing is provably
# firstmate's own) and failing loudly on a present-but-unreadable one - which
# includes a record written by an older schema without a commands object: a
# record this reader cannot prove exact must stop the caller rather than let
# it guess at ownership.
_fm_control_claude_settings_recorded_commands() {
  local record_path=$1
  if [ ! -e "$record_path" ]; then
    printf '%s' '{}'
    return 0
  fi
  jq -ce '.commands | select(type == "object")' "$record_path" 2>/dev/null || {
    echo "error: $record_path is not a readable firstmate claude-settings ownership record; refusing to guess which hook entries are firstmate's own" >&2
    return 1
  }
}

# fm_control_claude_settings_mergeable <settings-path>: true when install can
# merge into <settings-path> without destroying anything - the file is absent,
# zero-byte, or a JSON object whose "hooks" value (when present) is an object.
# fm-spawn.sh probes this BEFORE arming the busy contract so an unmergeable
# committed file refuses the spawn without leaving armed busy records behind;
# install re-checks it as the write-time authority.
fm_control_claude_settings_mergeable() {
  local path=$1
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 0
  [ -s "$path" ] || return 0
  jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$path" >/dev/null 2>&1
}

# fm_control_claude_settings_install <settings-path> <hooks-fragment-json> <record-path>:
# merge <hooks-fragment-json> - a {"UserPromptSubmit":[...],"Stop":[...],...}
# object holding exactly firstmate's managed hook entries - into the settings
# file at <settings-path>, and union the commands inside those entries into
# <record-path> as the ownership authority every later strip, clear, or
# restore decision uses. Every hook whose command a previous incarnation
# recorded is stripped before the fresh entries are appended, so a respawn
# replaces firstmate's own entries instead of accumulating them; every other
# top-level key, every other hook event, and every hook whose command is not
# recorded passes through unchanged. An existing non-empty file that is not a
# JSON object with an object (or absent) "hooks" key is refused with the
# original bytes untouched - there is deliberately no fallback that writes
# over content this function cannot prove it can merge; a zero-byte file
# merges as the empty object. The monotone record (old commands unioned with
# fresh, see the section comment above) is written before the settings file
# so no window exists where any entry of firstmate's is on disk without a
# record that identifies it; both writes are atomic same-directory renames.
fm_control_claude_settings_install() {
  local path=$1 fresh=$2 record_path=$3 base old_cmds preexisted record merged tmp
  [ -n "$path" ] && [ -n "$fresh" ] && [ -n "$record_path" ] || return 1
  if [ -e "$path" ]; then
    if ! fm_control_claude_settings_mergeable "$path"; then
      echo "error: $path exists but is not a JSON object firstmate can merge its claude hooks into; escalate to the captain to fix or remove that file in the project, then respawn (it is never overwritten: a project's own settings must survive a spawn)" >&2
      return 1
    fi
    if [ -s "$path" ]; then
      base=$(cat "$path") || return 1
    else
      base='{}'
    fi
    preexisted=true
  else
    base='{}'
    preexisted=false
  fi
  old_cmds=$(_fm_control_claude_settings_recorded_commands "$record_path") || return 1
  # preexisted describes the state before firstmate's FIRST install for the
  # task: a re-install always finds the file present (the previous install
  # wrote it), so the prior record's value carries forward.
  if [ -e "$record_path" ]; then
    preexisted=$(jq -r 'if .preexisted == false then "false" else "true" end' "$record_path" 2>/dev/null) || preexisted=true
  fi
  merged=$(printf '%s' "$base" \
    | jq -c --argjson rec "$old_cmds" --argjson fresh "$fresh" \
        "$_FM_CONTROL_CLAUDE_SETTINGS_INSTALL_JQ") || {
    echo "error: could not merge firstmate's claude hooks into $path; the file was left untouched" >&2
    return 1
  }
  record=$(jq -nc --argjson old "$old_cmds" --argjson fresh "$fresh" \
    --argjson preexisted "$preexisted" "$_FM_CONTROL_CLAUDE_SETTINGS_RECORD_JQ") || return 1
  tmp="$record_path.tmp.$$"
  if ! printf '%s\n' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record_path"; then
    rm -f -- "$tmp"
    return 1
  fi
  tmp="$path.tmp.$$"
  if ! printf '%s\n' "$merged" > "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# fm_control_claude_settings_clear <settings-path> <record-path>: remove the
# hook entries the ownership record proves firstmate wrote, in place, then
# retire the record, so a relaunch or a harness switch never deletes a
# project's own content the way a blind rm -f would. A file the record says
# firstmate itself created is removed entirely once nothing but firstmate's
# own entries remains in it, so an aborted or retired incarnation leaves no
# trace of a file the project never had; a pre-existing file is only ever
# rewritten without firstmate's entries, and left byte-untouched when none of
# them are present. With no record nothing is provably firstmate's own and
# the file is left alone entirely. An unparseable settings file is also left
# alone, with its record kept and a warning: an unparseable file fires no
# hooks, and the next install or teardown will refuse loudly instead of
# guessing.
fm_control_claude_settings_clear() {
  local path=$1 record_path=$2 cmds stripped tmp
  [ -n "$path" ] && [ -n "$record_path" ] || return 1
  [ -e "$record_path" ] || return 0
  cmds=$(_fm_control_claude_settings_recorded_commands "$record_path") || return 1
  if [ ! -e "$path" ]; then
    rm -f -- "$record_path" || return 1
    return 0
  fi
  if ! stripped=$(jq -c --argjson rec "$cmds" "$_FM_CONTROL_CLAUDE_SETTINGS_STRIP_ONLY_JQ" "$path" 2>/dev/null); then
    echo "warning: $path is not parseable JSON; leaving it and its ownership record $record_path in place rather than guessing" >&2
    return 0
  fi
  if jq -e '.preexisted == false' "$record_path" >/dev/null 2>&1 \
      && [ "$(printf '%s' "$stripped" | jq -S -c "$_FM_CONTROL_CLAUDE_SETTINGS_NORM_JQ")" = '{}' ]; then
    rm -f -- "$path" || return 1
    rm -f -- "$record_path" || return 1
    return 0
  fi
  if [ "$stripped" = "$(jq -c . "$path")" ]; then
    # Nothing of firstmate's is in the file; skip the rewrite so a project
    # file's own formatting stays byte-untouched.
    rm -f -- "$record_path" || return 1
    return 0
  fi
  tmp="$path.tmp.$$"
  if ! printf '%s\n' "$stripped" > "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$record_path"
}

# fm_control_claude_settings_only_owned_differ <head-json> <wt-json> <record-path>:
# true when the working-tree document becomes identical to the HEAD document
# once the hooks whose commands the ownership record proves firstmate wrote
# are stripped from the working-tree side - i.e. the only difference is
# firstmate's own installed hooks. Both sides are normalized (sorted keys; an
# event left as an empty array, or a hooks object left empty, compares equal
# to that key being absent, and an empty document compares as the empty
# object) so stripping firstmate's entries out of an event it created cannot
# manufacture a difference. Stripping touches the working-tree side only: if
# HEAD itself somehow contains one of the recorded commands, the sides stay
# different and the caller keeps refusing. An absent or unreadable record, or
# malformed JSON on either side, is never provably hooks-only, so it returns
# false: keep a real dirty refusal rather than risk discarding content this
# predicate cannot account for.
fm_control_claude_settings_only_owned_differ() {
  local head=$1 wt=$2 record_path=$3 cmds head_norm wt_norm
  [ -n "$record_path" ] && [ -e "$record_path" ] || return 1
  cmds=$(_fm_control_claude_settings_recorded_commands "$record_path") || return 1
  head_norm=$(printf '%s' "$head" | jq -S -c "$_FM_CONTROL_CLAUDE_SETTINGS_NORM_JQ" 2>/dev/null) || return 1
  wt_norm=$(printf '%s' "$wt" \
    | jq -S -c --argjson rec "$cmds" "$_FM_CONTROL_CLAUDE_SETTINGS_STRIP_NORM_JQ" 2>/dev/null) || return 1
  [ -n "$head_norm" ] || head_norm='{}'
  [ -n "$wt_norm" ] || wt_norm='{}'
  [ "$head_norm" = "$wt_norm" ]
}
