#!/usr/bin/env bash
# fm-harness-adapter.sh - the ONE owner of firstmate's per-harness turn-end and
# busy-state ARTIFACT set: which files each adapter's wiring writes, and
# therefore which files teardown must remove.
#
# This mirrors bin/fm-backend.sh + bin/backends/<name>.sh on the harness axis:
# a BACKEND is the session provider a task runs inside (tmux, herdr, zellij,
# orca, cmux), while a HARNESS is the agent CLI running inside it (claude,
# codex, opencode, pi, pi-signed, grok, kimi).
#
# Scope note: this file owns the artifact INVENTORY only. The semantic
# busy-state contract - what busy means, which source is trusted for which
# harness, and how records are classified - is owned by bin/fm-busy-lib.sh and
# is deliberately not duplicated or re-litigated here.
#
# Why it exists. bin/fm-spawn.sh installs a per-harness wiring file, and
# bin/fm-teardown.sh removes it - but the removal list was written out by hand
# in SIX places (four worktree `rm -f` blocks, two state-dir blocks) plus a
# seventh spelling in the dirty-check allowlist, with nothing forcing them to
# agree. They drifted, and the drift is not hypothetical:
#
#   OpenCode's wiring file was renamed .opencode/plugins/fm-turn-end.js ->
#   .opencode/plugins/fm-busy-state.js. Two of the four worktree blocks were
#   updated; the orca-child path and the ORDINARY task path were not. Both
#   still remove the old name, which fm-spawn no longer writes, so on the
#   ordinary teardown path an OpenCode task cleaned nothing at all and left the
#   plugin in a worktree that treehouse then returned to the pool. The
#   busy-state `gen` guard (bin/fm-busy-lib.sh) keeps a leaked plugin from
#   classifying a later task, so the damage is a leaked untracked file plus a
#   dirty-check refusal risk on the next teardown, not a false busy verdict.
#
# Consolidating the list here is what stops that recurring: install and every
# removal path now read the same data, so a renamed or added artifact cannot be
# updated in one place and forgotten in six.
#
# Removal is deliberately the UNION across every known harness, not just the
# task's recorded one. That matches the behavior teardown always had, and it
# stays correct for a task whose recorded harness is missing, unreadable, or no
# longer matches what actually ran. Installation is per-harness, because only
# the launching adapter knows what it wrote.
#
# Sourcing this file loads every adapter in bin/harnesses/ (see "adapter
# loading" at the foot of the file). It has no other side effects: nothing is
# written and no external command is run.

FM_HARNESS_ADAPTER_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_HARNESS_ADAPTER_LIB_DIR="$(cd "$(dirname "$FM_HARNESS_ADAPTER_SCRIPT")" && pwd)"
unset FM_HARNESS_ADAPTER_SCRIPT

# Verified harness adapters. Extend only after a harness gets its own
# bin/harnesses/<name>.sh and empirical verification, mirroring the backend
# axis's adapter-verification discipline (AGENTS.md section 4).
#
# TWO name sets, deliberately different. Do NOT collapse them:
#   FM_HARNESS_KNOWN    launchable as a crewmate or secondmate (docs/configuration.md)
#   FM_HARNESS_PRIMARY  supported for the PRIMARY session (README.md "Requirements")
# kimi is verified for crewmate and secondmate launches but is NOT a supported
# primary harness, which is why docs/supervision-protocols/ has no kimi.md and
# bin/fm-supervision-instructions.sh has no kimi arm. Those absences are
# correct; a single merged list would silently promote kimi to a primary harness.
FM_HARNESS_KNOWN="claude codex opencode pi pi-signed grok kimi"
FM_HARNESS_PRIMARY="claude codex opencode pi pi-signed grok"

# fm_harness_list_contains: whitespace-delimited membership without relying on
# shell word splitting, mirroring fm_backend_list_contains. This file is
# normally sourced by bash, but zsh diagnostics can source it too, so name
# matching must stay portable.
fm_harness_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_harness_is_known() {  # <name>
  fm_harness_list_contains "$FM_HARNESS_KNOWN" "$1"
}

fm_harness_is_primary() {  # <name>
  fm_harness_list_contains "$FM_HARNESS_PRIMARY" "$1"
}

# fm_harness_adapter_name: the adapter FILE a harness resolves to. pi-signed is
# Pi's distinct signed-wrapper identity, not a separate agent, so it shares
# bin/harnesses/pi.sh. Resolving the alias exactly once here is what lets call
# sites drop their own `pi|pi-signed)` arms.
fm_harness_adapter_name() {  # <name> -> adapter base name on stdout, or 1
  local adapter
  _fm_harness_adapter_name_into adapter "$1" || return 1
  printf '%s' "$adapter"
}

# The same mapping assigned to <varname> instead of printed, so callers resolve
# it without a command substitution. The alias lives here and nowhere else.
_fm_harness_adapter_name_into() {  # <varname> <name>
  local _var=$1 name=$2
  fm_harness_is_known "$name" || return 1
  case "$name" in
    pi-signed) printf -v "$_var" '%s' pi ;;
    *) printf -v "$_var" '%s' "$name" ;;
  esac
}

# The distinct adapter FILES, in a stable order. pi-signed is absent on purpose:
# it resolves to pi, and listing both would double every union.
FM_HARNESS_ADAPTERS="claude codex opencode pi grok kimi"

# fm_harness_launch_adapter_name: the adapter whose wiring a LAUNCHED harness
# name installs. fm-spawn's install arms match by GLOB (claude*, opencode*,
# ...), and its raw-launch escape hatch can hand them a variant name like
# claude-nightly that still writes claude's artifacts, so exact
# FM_HARNESS_KNOWN membership is the wrong test for anything mirroring
# installation. These patterns must stay in step with fm-spawn's install arms.
fm_harness_launch_adapter_name() {  # <name> -> adapter base name on stdout, or 1
  case "$1" in
    claude*) printf '%s' claude ;;
    opencode*) printf '%s' opencode ;;
    pi|pi-signed) printf '%s' pi ;;
    codex*) printf '%s' codex ;;
    grok*) printf '%s' grok ;;
    kimi*) printf '%s' kimi ;;
    *) return 1 ;;
  esac
}

fm_harness_source() {  # <name>
  local adapter
  _fm_harness_adapter_name_into adapter "$1" || return 1
  case "$adapter" in
    claude)
      if [ -z "${_FM_HARNESS_CLAUDE_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/claude.sh" || return 1
        _FM_HARNESS_CLAUDE_SOURCED=1
      fi
      ;;
    codex)
      if [ -z "${_FM_HARNESS_CODEX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/codex.sh" || return 1
        _FM_HARNESS_CODEX_SOURCED=1
      fi
      ;;
    opencode)
      if [ -z "${_FM_HARNESS_OPENCODE_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/opencode.sh" || return 1
        _FM_HARNESS_OPENCODE_SOURCED=1
      fi
      ;;
    pi)
      if [ -z "${_FM_HARNESS_PI_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/pi.sh" || return 1
        _FM_HARNESS_PI_SOURCED=1
      fi
      ;;
    grok)
      if [ -z "${_FM_HARNESS_GROK_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/grok.sh" || return 1
        _FM_HARNESS_GROK_SOURCED=1
      fi
      ;;
    kimi)
      if [ -z "${_FM_HARNESS_KIMI_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/kimi.sh" || return 1
        _FM_HARNESS_KIMI_SOURCED=1
      fi
      ;;
    *) return 1 ;;
  esac
}

# --- artifact inventory ------------------------------------------------------
#
# Each adapter declares two newline-separated lists, either of which may be
# empty (codex installs nothing - its turn-end rides the launch command):
#
#   FM_HARNESS_<NAME>_WORKTREE_ARTIFACTS  paths RELATIVE to the task worktree.
#                                          These are what fm-spawn writes and
#                                          adds to info/exclude, and what
#                                          fm-teardown removes from the worktree.
#   FM_HARNESS_<NAME>_STATE_ARTIFACTS      names RELATIVE to the state dir, with
#                                          the literal token @ID@ standing for
#                                          the task id.
#
# Names are read indirectly so the union stays one loop rather than six arms.

# _fm_harness_adapter_var: value of <ADAPTER>'s <SUFFIX> list, or empty.
_fm_harness_adapter_var() {  # <adapter> <suffix>
  local upper
  upper=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  eval "printf '%s' \"\${FM_HARNESS_${upper}_${2}:-}\""
}

# fm_harness_worktree_artifacts: the worktree-relative artifacts ONE harness
# installs. Used by fm-spawn for info/exclude. Empty output is valid.
fm_harness_worktree_artifacts() {  # <harness>
  local adapter
  _fm_harness_adapter_name_into adapter "$1" || return 1
  _fm_harness_adapter_var "$adapter" WORKTREE_ARTIFACTS
}

# fm_harness_worktree_artifacts_all: the UNION across every known adapter, one
# path per line, deduplicated and stably ordered. This is what every teardown
# removal path uses; see the header for why removal is a union.
fm_harness_worktree_artifacts_all() {
  local adapter
  for adapter in $FM_HARNESS_ADAPTERS; do
    _fm_harness_adapter_var "$adapter" WORKTREE_ARTIFACTS
    printf '\n'
  done | awk 'NF && !seen[$0]++'
}

# fm_harness_state_artifacts_all: the same union for state-dir artifacts, with
# @ID@ replaced by <id>. One name per line. The substitution is a QUOTED shell
# parameter expansion because it must be byte-exact: fm_task_id_path_safe
# guards the main teardown id, but cleanup_firstmate_home_children derives
# child ids from basename with no charset guarantee, and an id carrying a
# character a replacement engine treats specially (`&` or `\` in awk's gsub,
# and in bash 5.2+ patsub_replacement unless the replacement is quoted) would
# mangle the derived name and quietly skip the removal.
fm_harness_state_artifacts_all() {  # <id>
  local id=$1 adapter name
  for adapter in $FM_HARNESS_ADAPTERS; do
    _fm_harness_adapter_var "$adapter" STATE_ARTIFACTS
    printf '\n'
  done | while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "${name//@ID@/"$id"}"
  done | awk '!seen[$0]++'
}

# fm_harness_dirty_allow_re: the extended-regex alternation fm-teardown's
# uncommitted-changes filter uses to ignore firstmate's OWN wiring files.
#
# Derived from the same union rather than spelled a seventh time. The shape
# matters: `git status --porcelain` reports an entirely untracked directory as
# its top-level prefix (`?? .claude/`), never as the file inside it, so a
# nested artifact contributes its first path component plus a slash, while a
# top-level file contributes its exact name anchored with `$`.
#
# Every literal is regex-escaped before the trailing anchor is appended, so a
# dot in a filename cannot widen the match. Unescaped, `.claude/` would also
# ignore a genuinely untracked `Xclaude/`, quietly weakening the very check that
# stops teardown discarding a crewmate's unlanded work.
fm_harness_dirty_allow_re() {
  fm_harness_worktree_artifacts_all \
    | awk '{
        if (index($0, "/")) { sub(/\/.*/, ""); anchor = "/" } else { anchor = "$" }
        gsub(/[].[^$()*+?{}|\\]/, "\\\\&")
        print $0 anchor
      }' \
    | awk '!seen[$0]++' \
    | paste -sd'|' -
}

# --- adapter loading ---------------------------------------------------------
#
# Every adapter is loaded here, once, when this file is sourced. They are pure
# data - a few lines each - so eager loading costs one negligible read and keeps
# every lookup a plain variable read. This is the deliberate difference from
# bin/fm-backend.sh, which loads lazily because its adapters are orders of
# magnitude larger and most consumers touch only one.
#
# This file is a library and is only ever sourced, so a bare `return` is the
# correct refusal: a consumer that cannot load the adapters must fail closed
# rather than run with an empty artifact list, which would silently make
# teardown remove nothing.
fm_harness_source_all() {
  local h
  for h in $FM_HARNESS_ADAPTERS; do
    fm_harness_source "$h" || return 1
  done
}
fm_harness_source_all || {
  echo "error: bin/harnesses adapters are missing or unreadable" >&2
  return 1
}
