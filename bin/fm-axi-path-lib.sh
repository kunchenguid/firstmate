#!/usr/bin/env bash
# fm-axi-path-lib.sh - resolve the directory holding the axi agent tools so a
# spawned direct report can actually run them.
#
# The hazard: the axi tools (tasks-axi, gh-axi, chrome-devtools-axi, lavish-axi)
# are npm globals installed into whichever Node toolchain was active when they
# were installed, e.g. a mise-managed ~/.local/share/mise/installs/node/<ver>/bin.
# That directory is on PATH only while that toolchain resolves. A crewmate works
# in a different project directory, and a project that pins its own toolchain
# (or ships a config file mise refuses to trust) resolves away from it, so the
# axi tools vanish from the crewmate's PATH ALL AT ONCE. Nothing is uninstalled;
# they are simply unreachable from where crewmates run. The generated brief still
# tells the crewmate to use gh-axi, and bin/fm-decision-hold.sh hard-requires
# tasks-axi, so the crewmate fails deep inside its task instead of at launch.
#
# fm-spawn.sh therefore resolves the directory HERE, in firstmate's own
# environment where the tools do resolve, and exports it into the spawned
# agent's shell.
#
# Three properties this deliberately holds:
#
#   1. The directory is resolved dynamically from where the tools actually live
#      (command -v, then dirname). A hardcoded node/<major> path would break
#      silently on the next toolchain bump and recreate this bug with extra
#      steps, so no Node version, mise layout, or install prefix is assumed.
#   2. It fails closed when NO axi tool resolves at all. That is the signature of
#      the actual bug - a whole toolchain resolving away - and it leaves no
#      directory to export, so the caller refuses the spawn rather than launching
#      an agent that is told to use tools it does not have. A silent partial
#      success is worse, because the failure then surfaces deep inside the task.
#   3. A tool missing while others resolve is an INSTALL gap, not a PATH gap.
#      Refusing every spawn over one uninstalled tool would be disproportionate,
#      so that warns loudly instead - the brief instruction is still never
#      silently false, but the fleet keeps moving.
#
# Callers use fm_axi_path_suffix, which prints a colon-joined PATH fragment to
# APPEND to the agent's PATH. It is appended, not prepended, on purpose: the tool
# directory is also a Node toolchain bin directory, and prepending it would
# shadow a project's own pinned node/npm. Appending still resolves the axi tools,
# because no other directory on the crewmate's PATH provides those names.

FM_AXI_TOOLS="tasks-axi gh-axi chrome-devtools-axi lavish-axi"

# fm_axi_tool_dir <tool> - print the absolute directory holding <tool>, or
# return 1 when it does not resolve to an executable on PATH.
fm_axi_tool_dir() {
  local path
  path=$(command -v "$1" 2>/dev/null) || return 1
  [ -n "$path" ] && [ -x "$path" ] || return 1
  cd "$(dirname "$path")" 2>/dev/null && pwd
}

# fm_axi_path_suffix - print the colon-joined directories to append to PATH.
# Returns 1 with an actionable diagnostic when no axi tool resolves at all.
# Warns on stderr for individually absent tools and still succeeds.
fm_axi_path_suffix() {
  local tool dir suffix missing
  suffix=
  missing=
  for tool in $FM_AXI_TOOLS; do
    if dir=$(fm_axi_tool_dir "$tool"); then
      # Normally every tool shares one directory, so this collapses to a single
      # entry; a split install is carried through rather than dropped.
      case ":$suffix:" in
        *":$dir:"*) ;;
        *) suffix="${suffix:+$suffix:}$dir" ;;
      esac
    else
      missing="$missing $tool"
    fi
  done
  if [ -z "$suffix" ]; then
    echo "error: cannot resolve the axi agent tool directory; none of these are on PATH:${missing}" >&2
    echo "  Crewmate instructions tell workers to use these tools and bin/fm-decision-hold.sh requires" >&2
    echo "  tasks-axi, so this spawn is refused rather than launching a worker that cannot run them." >&2
    echo "  This usually means the Node toolchain they were installed into is not active here." >&2
    echo "  Install them into the currently active toolchain (npm install -g tasks-axi gh-axi" >&2
    echo "  chrome-devtools-axi lavish-axi), or start firstmate where they resolve, then retry." >&2
    return 1
  fi
  if [ -n "$missing" ]; then
    echo "warning: axi tools not installed anywhere on PATH:${missing}" >&2
    echo "  The worker's instructions tell it to use them, so that instruction will be wrong for this" >&2
    echo "  spawn. Install them (npm install -g <tool>) to make it true again." >&2
  fi
  printf '%s\n' "$suffix"
}
