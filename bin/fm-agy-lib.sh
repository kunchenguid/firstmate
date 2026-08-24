#!/usr/bin/env bash
# Antigravity CLI (`agy`) executable resolution, model catalogue, and the paths
# of the ONE firstmate-owned global agy plugin.
# Sourced by bin/fm-spawn.sh. This file is sourced by scripts and has no side
# effects on source.
# bin/fm-control-lib.sh deliberately restates the registry path inline instead of
# sourcing this file, because it is a dependency-free contract; keep the two in
# step when this layout changes.
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

# fm_agy_settings_path: the agy CLI app-data settings file. FM_AGY_SETTINGS
# exists so tests can exercise the suppression against a scratch root.
fm_agy_settings_path() {
  printf '%s' "${FM_AGY_SETTINGS:-${HOME:-}/.gemini/antigravity-cli/settings.json}"
}

# fm_agy_suppress_feedback_survey: ensure showFeedbackSurvey is false in agy's
# settings.json. The feedback survey is an interactive stdin prompt
# ("[1] Good [2] Fine [3] Bad [0] Skip") that blocks autonomous workers
# indefinitely because nothing answers it. Setting showFeedbackSurvey to false
# in the settings file suppresses it permanently.
#
# The settings file may be a nix home-manager symlink into the read-only store.
# In that case this function replaces the symlink with a real file so the
# setting persists until the next home-manager activation, which is the same
# write semantics agy itself uses (atomic temp + rename). If jq is absent the
# function is a no-op: the survey is an annoyance, not a safety hazard, so
# failing open is correct.
fm_agy_suppress_feedback_survey() {
  local settings
  settings=$(fm_agy_settings_path)
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Fast path: already suppressed.
  if jq -e '.showFeedbackSurvey == false' "$settings" >/dev/null 2>&1; then
    return 0
  fi

  local tmp new_content
  new_content=$(jq '.showFeedbackSurvey = false' "$settings" 2>/dev/null) || return 0
  tmp="${settings}.fm-tmp.$$"
  if printf '%s\n' "$new_content" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$settings" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  else
    rm -f "$tmp" 2>/dev/null
  fi
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

# FM_AGY_PROBE_TIMEOUT: the wall-clock ceiling on the ONE agy subprocess this
# library runs. `agy models` is a NETWORK call, and bin/fm-spawn.sh runs it
# while holding the per-task spawn lock and the task-set lock, so an unbounded
# probe would wedge the whole spawn path - and every later spawn behind those
# locks - on a slow or black-holed connection. This is the same ceiling
# bin/fm-cursor-lib.sh puts on its own catalogue probe, for the same reason.
FM_AGY_PROBE_TIMEOUT=${FM_AGY_PROBE_TIMEOUT:-20}

# fm_agy_bounded_output: run an agy subcommand under a hard wall-clock bound, or
# refuse. Refusing when nothing can impose a bound is deliberate and is what
# makes this fail-safe rather than fail-slow: the caller's contract is that an
# unreachable probe establishes NOTHING, so declining to run it degrades to "not
# validated" instead of blocking a lock-holding spawn indefinitely.
#
# The perl fallback is not a nicety. A stock macOS has neither `timeout` nor
# `gtimeout` unless coreutils was installed by hand, so without it every probe
# on this library - the model catalogue AND the quota poll that holds the agy
# ladder's floor up - silently declined to run on exactly the platform the fleet
# runs on. perl ships with macOS and with every supported Linux, and this is the
# same fork/setpgrp/alarm bound bin/fm-nm-run-lib.sh already uses.
fm_agy_bounded_output() {  # <agy-binary> <args...>
  local path=$1 runner=none
  shift
  [ -n "$path" ] && [ -x "$path" ] || return 1
  if command -v timeout >/dev/null 2>&1; then runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then runner=gtimeout
  elif command -v perl >/dev/null 2>&1; then runner=perl
  fi
  # A probe borrows the CALLER's shell, and a pane multiplexer injects its pane
  # identity into every process in a pane, so an unstripped probe inherits the
  # caller's. That identity is what a harness status line reports its model,
  # context and quota against - and a probe runs a full headless agy session,
  # status line included. Left in place, a probe made from a Claude secondmate's
  # pane pushes agy's model and a fresh session's 0% context onto that pane,
  # flipping the agents sidebar to the probe's harness until the pane's own next
  # redraw. A probe owns no pane, so it must carry no pane identity.
  # bin/fm-test-run.sh strips the same set for the same reason.
  (
    unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HERDR_SOCKET_PATH HERDR_SESSION 2>/dev/null || true
    case "$runner" in
      timeout|gtimeout)
        "$runner" "$FM_AGY_PROBE_TIMEOUT" "$path" "$@" </dev/null 2>/dev/null
        ;;
      perl)
        perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
          "$FM_AGY_PROBE_TIMEOUT" "$path" "$@" </dev/null 2>/dev/null
        ;;
      *) return 1 ;;
    esac
  )
}

# fm_agy_list_models: the account's own live catalogue, one
# "<id><TAB><Display Name>" row per model. A caller that cannot reach it must
# treat the result as unknown rather than as proof a model is unsupported.
fm_agy_list_models() {  # <agy-binary>
  local out
  out=$(fm_agy_bounded_output "$1" models) || return 1
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
