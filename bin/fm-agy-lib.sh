#!/usr/bin/env bash
# Antigravity CLI (`agy`) executable resolution, model catalogue, and the paths
# of the ONE firstmate-owned global agy plugin.
# Sourced by bin/fm-spawn.sh and bin/fm-teardown.sh. This file is sourced by
# scripts and has no side effects on source.
#
# Why one owner: agy's turn-end and busy wiring is a GLOBAL customization, so
# its directory layout is shared by every firstmate home on the machine and by
# the captain's own agy sessions. A second copy of these paths would let a
# teardown miss exactly the registry entry a spawn wrote.
#
# WHERE THE WIRING LIVES, AND WHY IT IS A PLUGIN.
# agy discovers customizations from three roots (verified, agy 1.1.12, its own
# embedded `agy-customizations` guide): the workspace `.agents/` directory, the
# declared JSON configs, and the global `~/.gemini/config/`. The global root's
# own `hooks.json` is the natural home for a fleet-wide hook, but on this fleet
# it is a home-manager symlink into the read-only nix store that already
# carries the captain's `herdr-session` hook, so firstmate must never own that
# file. A plugin is the supported way to add hooks WITHOUT touching it: a
# directory under a customization root's `plugins/` holding a `plugin.json`
# marker and its own `hooks.json` is discovered automatically and is enabled by
# default with no entry in the captain's `config.json` (verified live: a
# firstmate-owned plugin fired SessionStart and Stop for a workspace carrying
# no `.agents/` of its own).
#
# Placing it in the workspace instead was rejected: agy's workspace root is
# `.agents/`, which in firstmate's OWN repo is tracked shared material, and a
# project that already ships `.agents/hooks.json` would need firstmate to merge
# JSON into a file it does not own.
#
# THE GUARD. The plugin is global, so it runs for the captain's own agy
# sessions too. It is a no-op for every session whose workspace does not hold a
# `.fm-agy-turnend` pointer naming a registry entry under
# `fm-turn-end.d/` - the same guarded shape bin/fm-spawn.sh installs for grok
# and Kimi - and it always prints `{}` on stdout, which is what agy requires of
# a hook, on every path including failure.

# fm_agy_config_home: agy's global customization root. FM_AGY_CONFIG_HOME
# exists so tests can exercise the real installer against a scratch root
# instead of the operator's own agy configuration.
fm_agy_config_home() {
  printf '%s' "${FM_AGY_CONFIG_HOME:-${HOME:-}/.gemini/config}"
}

# fm_agy_plugin_dir: the firstmate-owned plugin directory. Never the captain's
# own hooks.json beside it.
fm_agy_plugin_dir() {
  printf '%s/plugins/fm-turn-end' "$(fm_agy_config_home)"
}

# fm_agy_auth_dir: the private per-task registry the guard validates against.
fm_agy_auth_dir() {
  printf '%s/fm-turn-end.d' "$(fm_agy_plugin_dir)"
}

# fm_agy_pointer_path: the per-task worktree pointer naming a registry entry.
# Gitignored through the worktree's own git info/exclude by bin/fm-spawn.sh,
# exactly like grok's and Kimi's.
fm_agy_pointer_path() {  # <worktree>
  printf '%s/.fm-agy-turnend' "$1"
}

# fm_agy_resolve_binary: the absolute agy executable, or a failure naming what
# is missing. PATH first, then agy's own documented install location.
fm_agy_resolve_binary() {
  local candidate
  candidate=$(command -v agy 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    case "$candidate" in
      /*) printf '%s' "$candidate" ;;
      *) printf '%s' "$(cd "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate")" ;;
    esac
    return 0
  fi
  candidate="${HOME:-}/.local/bin/agy"
  if [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  echo "error: agy is not installed; no executable 'agy' on PATH and '${HOME:-}/.local/bin/agy' is absent" >&2
  return 1
}

# fm_agy_list_models: the account's own live catalogue, one
# "<id><TAB><Display Name>" row per model. Bounded because it is a network
# call. A caller that cannot reach it must treat the result as unknown rather
# than as proof a model is unsupported.
fm_agy_list_models() {  # <agy-binary>
  local out
  out=$("$1" models 2>/dev/null) || return 1
  printf '%s\n' "$out" | LC_ALL=C grep -v '^Fetching' | LC_ALL=C grep -e '	'
}

# fm_agy_catalog_has_model: 0 when <model> is a model the account can select.
# BOTH accepted spellings are checked, because agy accepts either: the kebab id
# in column 1 (gemini-3.1-pro-high) and the display name in column 2
# ("Gemini 3.1 Pro (High)"). Reads the catalogue on stdin.
fm_agy_catalog_has_model() {  # <model>
  local want=$1 line id display
  while IFS= read -r line; do
    id=${line%%	*}
    display=${line#*	}
    [ "$want" = "$id" ] && return 0
    [ "$want" = "$display" ] && return 0
  done
  return 1
}
